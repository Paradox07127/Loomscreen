import CoreGraphics
import Foundation
import LiveWallpaperCore

// MARK: - Monitor v2 board layout engine
//
// Pure geometry for the widget board — a native port of the interaction math in
// `monitor-design/board-mock.html`, reconciled with the CELL-EXACT persistence
// contract (`MonitorBoardConfiguration.packedPlacements`). Everything here is
// side-effect-free and unit-tested (`MonitorBoardLayoutEngineTests`); the
// SwiftUI/AppKit layers call in but hold no geometry of their own.
//
// Coordinate model (cell-exact):
//   • Normalized (x,y) ∈ 0…1 — the persisted top-left corner. NO margin or
//     gutter is baked in.
//   • Board pixels — normalized × board size. A widget's pixel footprint is a
//     pure multiple of the (margin-free, gutter-free) cell pitch.
//   • Visual gutters are the RENDERER's job: each tile's pixel rect is inset by
//     `tileInsetX/Y` per axis at draw time. Snap candidates and overlap tests
//     run on the RAW (pre-inset) cell rects, so tiles pack edge-to-edge in
//     stored coordinates while still showing a uniform gap on screen.
//
// A widget's normalized origin survives display changes; out-of-bounds
// placements clamp back on rather than being dropped (mock `relayoutAll`).

/// Cell geometry for one board size under the cell-exact model, sized to
/// Apple's official macOS widget frames (HIG Widgets → Specifications):
/// S 170×170, M 364×170, L 364×376 pt. Decomposed into a fixed-point cell
/// PITCH + per-axis render inset so all three frames come out exact:
/// visible = span×pitch − 2×inset ⇒ pitch 194/206 with insets 12/18 gives
/// 170/364 wide and 170/376 tall, with 24 pt horizontal / 36 pt vertical
/// gaps between flush neighbours — the same absolute size on every display,
/// like real desktop widgets. `columns`/`rows` are derived reference counts;
/// placements are free-form.
struct MonitorBoardGeometry: Equatable {
    let boardSize: CGSize
    let columns: Int
    let rows: Int
    /// Cell PITCH (gutter included) — a widget's RAW footprint is span × pitch.
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// Per-tile render inset creating the gutter; per axis because Apple's
    /// frame decomposition yields different h/v gaps (24 pt vs 36 pt).
    let tileInsetX: CGFloat
    let tileInsetY: CGFloat
    let cornerRadius: CGFloat
    /// Normalized top forbidden zone in pixels (menu-bar avoidance): the least y
    /// a widget origin may take. 0 on hosts that pass no `topInsetFraction`.
    let topInset: CGFloat

    static let appleCellPitch = CGSize(width: 194, height: 206)
    static let appleTileInset = CGSize(width: 12, height: 18)
    /// macOS desktop-widget corner radius.
    static let appleCornerRadius: CGFloat = 16

    init(boardSize: CGSize, referenceWidth: CGFloat = 0, topInsetFraction: CGFloat = 0) {
        // Point scale: 1 on the wallpaper (the board IS the screen). The
        // inspector preview passes the real display's width so its miniature
        // board renders Apple-size widgets to scale (WYSIWYG placements).
        let reference = referenceWidth > 0 ? referenceWidth : boardSize.width
        let s = reference > 0 ? boardSize.width / reference : 1

        let cw = Self.appleCellPitch.width * s
        let ch = Self.appleCellPitch.height * s
        self.boardSize = boardSize
        self.columns = cw > 0 ? max(Int((boardSize.width / cw).rounded(.down)), 1) : 1
        self.rows = ch > 0 ? max(Int((boardSize.height / ch).rounded(.down)), 1) : 1
        self.cellWidth = max(cw, 0)
        self.cellHeight = max(ch, 0)
        self.tileInsetX = Self.appleTileInset.width * s
        self.tileInsetY = Self.appleTileInset.height * s
        self.cornerRadius = max(Self.appleCornerRadius * s, 1)
        // Top forbidden zone (menu-bar avoidance), in board pixels.
        self.topInset = max(0, min(boardSize.height, boardSize.height * topInsetFraction))
    }

    var isDegenerate: Bool {
        boardSize.width <= 0 || boardSize.height <= 0 || cellWidth <= 0 || cellHeight <= 0
    }

    /// RAW pixel size of a widget footprint: a pure multiple of the cell pitch,
    /// with no gutter subtracted (the inset handles the visible gap).
    func pixelSize(columns cols: Int, rows spanRows: Int) -> CGSize {
        CGSize(width: CGFloat(cols) * cellWidth, height: CGFloat(spanRows) * cellHeight)
    }

    func pixelSize(for kind: MonitorWidgetKind, size: MonitorWidgetSize) -> CGSize {
        let cells = kind.cellSize(for: size)
        return pixelSize(columns: cells.columns, rows: cells.rows)
    }

    /// The rendered rect for a raw cell rect: inset per axis so neighbours that
    /// share an edge show the axis's gutter. Never inverts a tiny rect.
    func renderRect(forRawRect raw: CGRect) -> CGRect {
        let dx = min(tileInsetX, raw.width / 2)
        let dy = min(tileInsetY, raw.height / 2)
        return raw.insetBy(dx: dx, dy: dy)
    }

    /// Legal top-left range so the full RAW footprint stays on-board (edges may
    /// touch the board edges — cell-exact packing puts a full row flush to 0…1),
    /// with the top clamped to `topInset` so widgets never intrude on the
    /// menu-bar zone. Oversized footprints pin to the top-left / inset line.
    func clampOrigin(_ origin: CGPoint, footprint: CGSize) -> CGPoint {
        let maxX = boardSize.width - footprint.width
        let maxY = boardSize.height - footprint.height
        return CGPoint(
            x: MonitorBoardLayoutEngine.clamp(origin.x, 0, max(maxX, 0)),
            y: MonitorBoardLayoutEngine.clamp(origin.y, topInset, max(maxY, topInset))
        )
    }
}

/// A candidate alignment line surfaced during a drag so the view can draw the
/// magnetic guide. `axis == .vertical` is an x-line, `.horizontal` is a y-line.
/// `partner` is the sibling RAW rect the line aligns against (nil for board
/// edges / centre-lines, which the mock draws full-span).
struct MonitorSnapGuide: Equatable {
    enum Axis { case vertical, horizontal }
    var axis: Axis
    /// Position along the perpendicular axis, in board pixels (the line's x for
    /// a vertical guide, y for a horizontal one).
    var position: CGFloat
    var partner: CGRect?
}

/// Result of the magnetic snap solve for one drag frame.
struct MonitorSnapResult: Equatable {
    var origin: CGPoint
    var snappedX: Bool
    var snappedY: Bool
    var guideX: MonitorSnapGuide?
    var guideY: MonitorSnapGuide?

    var snapped: Bool { snappedX || snappedY }
}

/// One occupant of the board as the engine sees it: an identity plus its
/// current RAW (pre-inset) pixel rect. The interaction model builds these.
struct MonitorBoardItem: Equatable {
    var id: UUID
    var rect: CGRect
}

/// Namespace for the pure layout algorithms. All static; no stored state.
enum MonitorBoardLayoutEngine {

    /// Snap distance in points (mock `SNAP_TH = 14`).
    static let snapThreshold: CGFloat = 14
    /// Only siblings within this pixel neighbourhood of the dragged rect emit
    /// alignment candidates (mock `SNAP_NEAR = 140`).
    static let snapNeighborhood: CGFloat = 140
    /// Overlap slop so a shared edge counts as touching, not overlapping. In the
    /// cell-exact model neighbours legitimately share edges, so this keeps that
    /// from registering as an interpenetration (mock `EPS`).
    static let epsilon: CGFloat = 0.5

    static func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
        min(max(value, low), high)
    }

    // MARK: Normalized ↔ pixel

    /// Normalized top-left → pixel origin against a board size (mock: `x*bw`).
    static func pixelOrigin(normalized: CGPoint, boardSize: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * boardSize.width, y: normalized.y * boardSize.height)
    }

    /// Pixel origin → normalized (mock `setPos`: `x/bw`). Zero board ⇒ (0,0).
    static func normalized(pixelOrigin origin: CGPoint, boardSize: CGSize) -> CGPoint {
        CGPoint(
            x: boardSize.width > 0 ? origin.x / boardSize.width : 0,
            y: boardSize.height > 0 ? origin.y / boardSize.height : 0
        )
    }

    // MARK: AABB overlap

    /// True when two RAW rects interpenetrate. Shared/touching edges are legal
    /// (cell-exact neighbours pack flush), so the test uses `epsilon` slop: a
    /// conflict needs real overlap on BOTH axes. The visible gutter comes from
    /// the render inset, not from a coordinate gap.
    static func conflicts(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX - epsilon
            && a.maxX > b.minX + epsilon
            && a.minY < b.maxY - epsilon
            && a.maxY > b.minY + epsilon
    }

    /// A rect is legal when it sits inside the board and doesn't interpenetrate
    /// any other item (mock `legalAt`, adapted to cell-exact bounds).
    static func isLegal(
        rect: CGRect,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem],
        ignoring ignoredID: UUID?
    ) -> Bool {
        if rect.minX < -epsilon
            || rect.minY < geometry.topInset - epsilon
            || rect.maxX > geometry.boardSize.width + epsilon
            || rect.maxY > geometry.boardSize.height + epsilon {
            return false
        }
        for item in items {
            if item.id == ignoredID { continue }
            if conflicts(rect, item.rect) { return false }
        }
        return true
    }

    // MARK: Overlap resolution

    /// Resolve a requested origin to the nearest non-overlapping legal origin.
    ///
    /// Clamp on-board first; if already legal, return it. Otherwise build
    /// candidate x/y coordinates from each sibling's push-out edges (its far
    /// edge, or its near edge − footprint — flush, since edges may touch)
    /// crossed with the requested coordinate, and pick the nearest legal
    /// combination within `maxDisplacement`. Returns nil when nothing qualifies
    /// (the caller springs back). Port of the mock's `resolveRect`, with the
    /// cell-exact change that push-out is flush (no gutter added).
    static func resolve(
        origin requested: CGPoint,
        footprint: CGSize,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem],
        ignoring ignoredID: UUID?,
        maxDisplacement: CGFloat
    ) -> CGPoint? {
        let clamped = geometry.clampOrigin(requested, footprint: footprint)
        if isLegal(
            rect: CGRect(origin: clamped, size: footprint),
            geometry: geometry, items: items, ignoring: ignoredID
        ) {
            return clamped
        }

        var xs: [CGFloat] = [clamped.x]
        var ys: [CGFloat] = [clamped.y]
        for item in items where item.id != ignoredID {
            let r = item.rect
            xs.append(r.maxX)
            xs.append(r.minX - footprint.width)
            ys.append(r.maxY)
            ys.append(r.minY - footprint.height)
        }

        var best: CGPoint?
        var bestDistance = CGFloat.infinity
        for candidateX in xs {
            for candidateY in ys {
                let point = geometry.clampOrigin(CGPoint(x: candidateX, y: candidateY), footprint: footprint)
                let rect = CGRect(origin: point, size: footprint)
                if !isLegal(rect: rect, geometry: geometry, items: items, ignoring: ignoredID) { continue }
                let distance = hypot(point.x - clamped.x, point.y - clamped.y)
                if distance < bestDistance {
                    bestDistance = distance
                    best = point
                }
            }
        }
        if let best, bestDistance <= maxDisplacement { return best }
        return nil
    }

    // MARK: Magnetic snap

    /// Compute the snapped origin + alignment guides for a free (raw) drag
    /// origin. Each axis is solved independently. Candidates come from the board
    /// edges, the board centre-lines, and — for siblings within the snap
    /// neighbourhood — their L/R/centre edge alignments (which draw a guide)
    /// plus flush adjacency to their far/near edges (no guide; the ghost frame
    /// carries the meaning). The nearest candidate within `snapThreshold` wins;
    /// on a tie a guide-bearing candidate is preferred so its line isn't masked
    /// by an earlier guide-less one. Port of the mock's `computeSnap`, with
    /// cell-exact (flush) adjacency and board-edge candidates at 0 / boardW.
    static func snap(
        freeOrigin free: CGPoint,
        footprint: CGSize,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem],
        ignoring ignoredID: UUID?
    ) -> MonitorSnapResult {
        let bw = geometry.boardSize.width
        let bh = geometry.boardSize.height
        let dw = footprint.width
        let dh = footprint.height

        var snapX: CGFloat?
        var snapY: CGFloat?
        var guideX: MonitorSnapGuide?
        var guideY: MonitorSnapGuide?
        var bestDX = snapThreshold + 0.001
        var bestDY = snapThreshold + 0.001

        func considerX(target: CGFloat, guidePos: CGFloat?, partner: CGRect?) {
            let d = abs(free.x - target)
            if d < bestDX - 0.25 {
                bestDX = d
                snapX = target
                guideX = guidePos.map { MonitorSnapGuide(axis: .vertical, position: $0, partner: partner) }
            } else if let current = snapX, abs(target - current) < 0.5, guideX == nil, let guidePos {
                guideX = MonitorSnapGuide(axis: .vertical, position: guidePos, partner: partner)
            }
        }
        func considerY(target: CGFloat, guidePos: CGFloat?, partner: CGRect?) {
            let d = abs(free.y - target)
            if d < bestDY - 0.25 {
                bestDY = d
                snapY = target
                guideY = guidePos.map { MonitorSnapGuide(axis: .horizontal, position: $0, partner: partner) }
            } else if let current = snapY, abs(target - current) < 0.5, guideY == nil, let guidePos {
                guideY = MonitorSnapGuide(axis: .horizontal, position: guidePos, partner: partner)
            }
        }

        // Board edges + centre-lines (full-span guides). The top edge is the
        // menu-bar forbidden zone's lower line (`topInset`, 0 when unset).
        considerX(target: 0, guidePos: 0, partner: nil)
        considerX(target: bw - dw, guidePos: bw, partner: nil)
        considerX(target: (bw - dw) / 2, guidePos: bw / 2, partner: nil)
        considerY(target: geometry.topInset, guidePos: geometry.topInset, partner: nil)
        considerY(target: bh - dh, guidePos: bh, partner: nil)
        considerY(target: (bh - dh) / 2, guidePos: bh / 2, partner: nil)

        // Neighbouring widgets: edge alignment (with guide) + flush adjacency.
        for item in items where item.id != ignoredID {
            let r = item.rect
            let near = !(free.x > r.maxX + snapNeighborhood
                || free.x + dw < r.minX - snapNeighborhood
                || free.y > r.maxY + snapNeighborhood
                || free.y + dh < r.minY - snapNeighborhood)
            if !near { continue }
            considerX(target: r.minX, guidePos: r.minX, partner: r)                 // L-L
            considerX(target: r.maxX - dw, guidePos: r.maxX, partner: r)            // R-R
            considerX(target: r.midX - dw / 2, guidePos: r.midX, partner: r)        // C-C
            considerX(target: r.maxX, guidePos: nil, partner: r)                    // flush right
            considerX(target: r.minX - dw, guidePos: nil, partner: r)               // flush left
            considerY(target: r.minY, guidePos: r.minY, partner: r)
            considerY(target: r.maxY - dh, guidePos: r.maxY, partner: r)
            considerY(target: r.midY - dh / 2, guidePos: r.midY, partner: r)
            considerY(target: r.maxY, guidePos: nil, partner: r)
            considerY(target: r.minY - dh, guidePos: nil, partner: r)
        }

        return MonitorSnapResult(
            origin: CGPoint(x: snapX ?? free.x, y: snapY ?? free.y),
            snappedX: snapX != nil,
            snappedY: snapY != nil,
            guideX: guideX,
            guideY: guideY
        )
    }

    // MARK: Guide line segment geometry

    /// Concrete on-board line segment for a guide, matching the mock's
    /// `showSnapPreview`: a sibling-anchored guide spans the union of the
    /// dragged rect and the partner (± a small pad); a board-edge / centre guide
    /// spans the full board edge-to-edge.
    static func guideSegment(
        _ guide: MonitorSnapGuide,
        draggedRect: CGRect,
        geometry: MonitorBoardGeometry,
        pad: CGFloat = 12
    ) -> (start: CGPoint, end: CGPoint) {
        switch guide.axis {
        case .vertical:
            let x = guide.position
            if let p = guide.partner {
                let from = min(draggedRect.minY, p.minY) - pad
                let to = max(draggedRect.maxY, p.maxY) + pad
                return (CGPoint(x: x, y: from), CGPoint(x: x, y: to))
            }
            return (CGPoint(x: x, y: 0), CGPoint(x: x, y: geometry.boardSize.height))
        case .horizontal:
            let y = guide.position
            if let p = guide.partner {
                let from = min(draggedRect.minX, p.minX) - pad
                let to = max(draggedRect.maxX, p.maxX) + pad
                return (CGPoint(x: from, y: y), CGPoint(x: to, y: y))
            }
            return (CGPoint(x: 0, y: y), CGPoint(x: geometry.boardSize.width, y: y))
        }
    }

    // MARK: Drag landing

    /// Where a widget lands when the pointer is released. Prefers the snapped
    /// origin (unless snapping was bypassed), then runs overlap resolution with
    /// `maxDisplacement = max(dw, dh)` — nil ⇒ spring back to `origin` (mock
    /// `onDragEnd`).
    static func land(
        freeOrigin free: CGPoint,
        snappedOrigin: CGPoint?,
        footprint: CGSize,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem],
        ignoring ignoredID: UUID?
    ) -> CGPoint? {
        let target = snappedOrigin ?? free
        return resolve(
            origin: target,
            footprint: footprint,
            geometry: geometry,
            items: items,
            ignoring: ignoredID,
            maxDisplacement: max(footprint.width, footprint.height)
        )
    }

    // MARK: Size toggle re-fit

    /// New origin when a widget changes size, keeping its top-left anchor where
    /// possible. Tries the anchor, then (if the new footprint overhangs) small
    /// left/up shifts to the far edge before deferring to full overlap
    /// resolution. Returns nil when the new size can't be placed near the anchor
    /// at all (caller flashes "deny"). Mirrors the mock's `changeSize`.
    static func refitForSizeChange(
        anchor: CGPoint,
        newFootprint: CGSize,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem],
        ignoring ignoredID: UUID?
    ) -> CGPoint? {
        func legal(_ origin: CGPoint) -> CGPoint? {
            let clamped = geometry.clampOrigin(origin, footprint: newFootprint)
            let rect = CGRect(origin: clamped, size: newFootprint)
            return isLegal(rect: rect, geometry: geometry, items: items, ignoring: ignoredID) ? clamped : nil
        }

        if let atAnchor = legal(anchor) { return atAnchor }

        let shiftedLeft = CGPoint(x: geometry.boardSize.width - newFootprint.width, y: anchor.y)
        if shiftedLeft.x < anchor.x, let hit = legal(shiftedLeft) { return hit }
        let shiftedUp = CGPoint(x: anchor.x, y: geometry.boardSize.height - newFootprint.height)
        if shiftedUp.y < anchor.y, let hit = legal(shiftedUp) { return hit }
        let shiftedBoth = CGPoint(x: shiftedLeft.x, y: shiftedUp.y)
        if let hit = legal(shiftedBoth) { return hit }

        return resolve(
            origin: anchor,
            footprint: newFootprint,
            geometry: geometry,
            items: items,
            ignoring: ignoredID,
            maxDisplacement: max(newFootprint.width, newFootprint.height)
        )
    }

    // MARK: Add-widget first fit

    /// First-fit origin for a newly added widget: aim at the lower-centre band
    /// (mock `addWidget` targets `((bw-dw)/2, bh*0.64)`), resolve to the nearest
    /// free slot, then apply one in-threshold snap toward a neighbour if that
    /// snapped position is itself legal. Returns nil when the board is full.
    static func firstFit(
        footprint: CGSize,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem]
    ) -> CGPoint? {
        let target = CGPoint(
            x: (geometry.boardSize.width - footprint.width) / 2,
            y: geometry.boardSize.height * 0.64
        )
        guard let spot = resolve(
            origin: target,
            footprint: footprint,
            geometry: geometry,
            items: items,
            ignoring: nil,
            maxDisplacement: .greatestFiniteMagnitude
        ) else {
            return nil
        }
        let snapResult = snap(
            freeOrigin: spot,
            footprint: footprint,
            geometry: geometry,
            items: items,
            ignoring: nil
        )
        if snapResult.snapped {
            let rect = CGRect(origin: snapResult.origin, size: footprint)
            if isLegal(rect: rect, geometry: geometry, items: items, ignoring: nil) {
                return snapResult.origin
            }
        }
        return spot
    }
}
