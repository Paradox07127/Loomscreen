import CoreGraphics
import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

/// Pure-geometry tests for the Monitor v2 board engine. No UI — every case
/// exercises `MonitorBoardLayoutEngine` / `MonitorBoardGeometry` directly, so
/// they pin the ported math from `board-mock.html` under the CELL-EXACT
/// coordinate contract (positions on cell boundaries, no baked margin/gutter;
/// visual gutters are a render-time inset).
final class MonitorBoardLayoutEngineTests: XCTestCase {

    // A generous 16:10 reference board so several M widgets fit side by side.
    private let boardSize = CGSize(width: 1600, height: 1000)

    private func makeGeometry() -> MonitorBoardGeometry {
        MonitorBoardGeometry(boardSize: boardSize)
    }

    private func item(_ id: UUID, _ rect: CGRect) -> MonitorBoardItem {
        MonitorBoardItem(id: id, rect: rect)
    }

    /// Fill a board wall-to-wall with `size` widgets of `kind`, flush-packed
    /// (cell-exact). Used to build a genuinely full board — a 10-column board is
    /// never full with a single small widget.
    private func fillBoard(
        _ geometry: MonitorBoardGeometry, kind: MonitorWidgetKind, size: MonitorWidgetSize
    ) -> [MonitorBoardItem] {
        let fp = geometry.pixelSize(for: kind, size: size)
        var items: [MonitorBoardItem] = []
        var y: CGFloat = 0
        while y + fp.height <= geometry.boardSize.height + 0.5 {
            var x: CGFloat = 0
            while x + fp.width <= geometry.boardSize.width + 0.5 {
                items.append(item(UUID(), CGRect(x: x, y: y, width: fp.width, height: fp.height)))
                x += fp.width
            }
            y += fp.height
        }
        return items
    }

    // MARK: - Geometry basics

    func testVisualGutterTokenClamp() {
        XCTAssertEqual(MonitorBoardGeometry.visualGutter(forBoardWidth: 800), 12, accuracy: 0.001)
        XCTAssertEqual(MonitorBoardGeometry.visualGutter(forBoardWidth: 1600), 14.4, accuracy: 0.001)
        XCTAssertEqual(MonitorBoardGeometry.visualGutter(forBoardWidth: 4000), 20, accuracy: 0.001)
    }

    func testCellIsBoardWidthOverTen() {
        let g = makeGeometry()
        XCTAssertEqual(g.columns, 10)
        XCTAssertEqual(g.cellWidth, boardSize.width / 10, accuracy: 0.001)
        // Ten cells span the full board width, edge to edge (cell-exact).
        XCTAssertEqual(CGFloat(g.columns) * g.cellWidth, boardSize.width, accuracy: 0.001)
        // Tile inset is half the visual gutter.
        XCTAssertEqual(g.tileInset, MonitorBoardGeometry.visualGutter(forBoardWidth: boardSize.width) / 2, accuracy: 0.001)
    }

    func testFootprintIsPureCellMultiple() {
        let g = makeGeometry()
        // No gutter subtracted — footprint is exactly cells × cell size.
        let medium = g.pixelSize(for: .cpu, size: .medium) // 2×1
        XCTAssertEqual(medium.width, 2 * g.cellWidth, accuracy: 0.001)
        XCTAssertEqual(medium.height, 1 * g.cellHeight, accuracy: 0.001)
        let small = g.pixelSize(for: .clock, size: .small) // 1×1
        XCTAssertEqual(small.width, 1 * g.cellWidth, accuracy: 0.001)
        XCTAssertEqual(small.height, 1 * g.cellHeight, accuracy: 0.001)
    }

    func testFullTenColumnRowEndsAtBoardEdge() {
        let g = makeGeometry()
        // Five medium (2-col) widgets packed flush fill the row to the edge.
        let m = g.pixelSize(for: .cpu, size: .medium)
        XCTAssertEqual(5 * m.width, boardSize.width, accuracy: 0.001)
    }

    func testRenderRectInsetsForGutter() {
        let g = makeGeometry()
        let raw = CGRect(x: 100, y: 100, width: 400, height: 200)
        let rendered = g.renderRect(forRawRect: raw)
        XCTAssertEqual(rendered.minX, raw.minX + g.tileInset, accuracy: 0.001)
        XCTAssertEqual(rendered.minY, raw.minY + g.tileInset, accuracy: 0.001)
        XCTAssertEqual(rendered.width, raw.width - 2 * g.tileInset, accuracy: 0.001)
        // Two edge-sharing raw tiles show a full visual gutter between renders.
        let rawRight = CGRect(x: raw.maxX, y: 100, width: 400, height: 200)
        let renderedRight = g.renderRect(forRawRect: rawRight)
        XCTAssertEqual(renderedRight.minX - rendered.maxX, 2 * g.tileInset, accuracy: 0.001)
        XCTAssertEqual(2 * g.tileInset, MonitorBoardGeometry.visualGutter(forBoardWidth: boardSize.width), accuracy: 0.001)
    }

    func testDegenerateBoardFlagged() {
        XCTAssertTrue(MonitorBoardGeometry(boardSize: .zero).isDegenerate)
        XCTAssertFalse(makeGeometry().isDegenerate)
    }

    // MARK: - Square cells + reference row count (bug fix #5: cell height tracks
    // width so S/L are exact squares and M an exact 2:1 at ANY board aspect,
    // replacing the old aspect-derived row height that skewed cells off 16:10)

    /// `cellHeight == cellWidth == W / 10`; `rows = max(floor(H / cellHeight), 1)`
    /// is a reference count only. Hand-derived (columns = 10):
    ///   16:10 (1600×1000): cw = ch = 160, rows = floor(1000/160) = 6
    ///   16:9  (1600×900):  cw = ch = 160, rows = floor(900/160)  = 5
    ///   3:1   (1200×400):  cw = ch = 120, rows = floor(400/120)  = 3
    ///   9:16  (900×1600):  cw = ch = 90,  rows = floor(1600/90)  = 17
    func testSquareCellsAndReferenceRowCount() {
        let g1610 = MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(g1610.cellWidth, 160, accuracy: 0.001)
        XCTAssertEqual(g1610.cellHeight, 160, accuracy: 0.001) // square, == cellWidth
        XCTAssertEqual(g1610.rows, 6)

        let g169 = MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 900))
        XCTAssertEqual(g169.cellHeight, 160, accuracy: 0.001) // square regardless of aspect
        XCTAssertEqual(g169.rows, 5)

        let gWide = MonitorBoardGeometry(boardSize: CGSize(width: 1200, height: 400))
        XCTAssertEqual(gWide.cellWidth, 120, accuracy: 0.001)
        XCTAssertEqual(gWide.cellHeight, 120, accuracy: 0.001)
        XCTAssertEqual(gWide.rows, 3)

        let gPortrait = MonitorBoardGeometry(boardSize: CGSize(width: 900, height: 1600))
        XCTAssertEqual(gPortrait.cellWidth, 90, accuracy: 0.001)
        XCTAssertEqual(gPortrait.cellHeight, 90, accuracy: 0.001)
        XCTAssertEqual(gPortrait.rows, 17)
    }

    /// Regression for the widget-distortion complaint: cells are now square by
    /// construction (ratio exactly 1.0) at every board aspect, not the old
    /// aspect-derived stretch.
    func testCellsAreExactlySquare() {
        let g = makeGeometry() // 16:10 reference board
        let ratio = g.cellHeight / g.cellWidth
        XCTAssertEqual(ratio, 1.0, accuracy: 0.001)
        // …and off 16:10 too.
        let g169 = MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 900))
        XCTAssertEqual(g169.cellHeight / g169.cellWidth, 1.0, accuracy: 0.001)
    }

    // MARK: - Corner radius (bug fix: was up to ~23pt on a full board; now 7% of
    // the smaller cell dimension, clamped to 6...12pt)

    /// Hand-derived (`cornerRadius = clamp(min(cw, ch) * 0.07, 6...12)`; cells
    /// square, columns = 10, so min(cw,ch) = cw = W/10):
    ///   16:10 (1600×1000): cw = 160 → *0.07 = 11.2 (in range)
    ///   3:1   (1200×400):  cw = 120 → *0.07 = 8.4  (in range)
    ///   tiny 16:10 (120×75):     cw = 12  → *0.07 = 0.84 → floors to 6
    ///   huge 16:10 (3000×1875):  cw = 300 → *0.07 = 21   → ceilings to 12
    func testCornerRadiusIsSmallAndClamped() {
        let g1610 = MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(g1610.cornerRadius, 11.2, accuracy: 0.001) // in range at 10 columns

        let gWide = MonitorBoardGeometry(boardSize: CGSize(width: 1200, height: 400))
        XCTAssertEqual(gWide.cornerRadius, 8.4, accuracy: 0.001)

        let gTiny = MonitorBoardGeometry(boardSize: CGSize(width: 120, height: 75))
        XCTAssertEqual(gTiny.cornerRadius, 6, accuracy: 0.001) // floor

        let gHuge = MonitorBoardGeometry(boardSize: CGSize(width: 3000, height: 1875))
        XCTAssertEqual(gHuge.cornerRadius, 12, accuracy: 0.001) // ceiling
    }

    // MARK: - Normalized ↔ pixel round-trip

    func testNormalizedPixelRoundTrip() {
        let normalized = CGPoint(x: 0.375, y: 0.62)
        let px = MonitorBoardLayoutEngine.pixelOrigin(normalized: normalized, boardSize: boardSize)
        XCTAssertEqual(px.x, 600, accuracy: 0.001)
        XCTAssertEqual(px.y, 620, accuracy: 0.001)
        let back = MonitorBoardLayoutEngine.normalized(pixelOrigin: px, boardSize: boardSize)
        XCTAssertEqual(back.x, normalized.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, normalized.y, accuracy: 1e-9)
    }

    func testCellExactNormalizedOriginRoundTrips() {
        let g = makeGeometry()
        // x = 3/10 (a cell boundary) → pixel 3*cellW → back to 3/10.
        let normalized = CGPoint(x: 3.0 / 10.0, y: 0)
        let px = MonitorBoardLayoutEngine.pixelOrigin(normalized: normalized, boardSize: boardSize)
        XCTAssertEqual(px.x, 3 * g.cellWidth, accuracy: 0.001)
        let back = MonitorBoardLayoutEngine.normalized(pixelOrigin: px, boardSize: boardSize)
        XCTAssertEqual(back.x, 3.0 / 10.0, accuracy: 1e-9)
    }

    func testNormalizedOnZeroBoardIsOrigin() {
        let back = MonitorBoardLayoutEngine.normalized(pixelOrigin: CGPoint(x: 42, y: 42), boardSize: .zero)
        XCTAssertEqual(back, .zero)
    }

    // MARK: - Clamp keeps footprint on-board

    func testClampPinsFootprintOnBoardAtEdges() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .cpu, size: .medium)

        // Cell-exact: a widget may sit flush to the board edge (no margin).
        let clamped = g.clampOrigin(CGPoint(x: 99999, y: 99999), footprint: footprint)
        XCTAssertEqual(clamped.x, boardSize.width - footprint.width, accuracy: 0.01)
        XCTAssertEqual(clamped.y, boardSize.height - footprint.height, accuracy: 0.01)

        let clampedLow = g.clampOrigin(CGPoint(x: -500, y: -500), footprint: footprint)
        XCTAssertEqual(clampedLow.x, 0, accuracy: 0.01)
        XCTAssertEqual(clampedLow.y, 0, accuracy: 0.01)

        XCTAssertTrue(MonitorBoardLayoutEngine.isLegal(
            rect: CGRect(origin: clamped, size: footprint),
            geometry: g, items: [], ignoring: nil
        ))
    }

    func testClampOversizedFootprintPinsToTopLeft() {
        let g = makeGeometry()
        let huge = CGSize(width: boardSize.width * 2, height: boardSize.height * 2)
        let clamped = g.clampOrigin(CGPoint(x: 500, y: 500), footprint: huge)
        XCTAssertEqual(clamped.x, 0, accuracy: 0.01)
        XCTAssertEqual(clamped.y, 0, accuracy: 0.01)
    }

    // MARK: - Top inset (menu-bar forbidden zone, bug fix #1)

    /// `topInsetFraction` = 0.05 on a 1000pt-tall board → topInset = 50px: the
    /// least y any widget origin may take.
    private func insetGeometry() -> MonitorBoardGeometry {
        MonitorBoardGeometry(boardSize: boardSize, topInsetFraction: 0.05)
    }

    func testTopInsetStoredAsPixels() {
        XCTAssertEqual(insetGeometry().topInset, 50, accuracy: 0.001)
        XCTAssertEqual(makeGeometry().topInset, 0, accuracy: 0.001) // default: no zone
    }

    func testTopInsetClampsOriginDownToInsetLine() {
        let g = insetGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        // An origin inside the zone is pushed down to the inset line…
        let clamped = g.clampOrigin(CGPoint(x: 200, y: 0), footprint: footprint)
        XCTAssertEqual(clamped.y, 50, accuracy: 0.001)
        // …one already below it is untouched.
        let below = g.clampOrigin(CGPoint(x: 200, y: 300), footprint: footprint)
        XCTAssertEqual(below.y, 300, accuracy: 0.001)
    }

    func testTopInsetRejectsRectIntrudingIntoZone() {
        let g = insetGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        // A rect whose top crosses the inset line is illegal…
        let intruding = CGRect(origin: CGPoint(x: 200, y: 20), size: footprint)
        XCTAssertFalse(MonitorBoardLayoutEngine.isLegal(rect: intruding, geometry: g, items: [], ignoring: nil))
        // …one resting exactly on it is legal.
        let onLine = CGRect(origin: CGPoint(x: 200, y: 50), size: footprint)
        XCTAssertTrue(MonitorBoardLayoutEngine.isLegal(rect: onLine, geometry: g, items: [], ignoring: nil))
    }

    func testTopInsetMovesTopSnapCandidateToInsetLine() {
        let g = insetGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        // Dragging just below the inset line snaps to it (not to y=0), with a guide.
        let free = CGPoint(x: 400, y: 54)
        let result = MonitorBoardLayoutEngine.snap(
            freeOrigin: free, footprint: footprint, geometry: g, items: [], ignoring: nil
        )
        XCTAssertTrue(result.snappedY)
        XCTAssertEqual(result.origin.y, 50, accuracy: 0.001)
        XCTAssertEqual(result.guideY?.position, 50)
    }

    // MARK: - AABB overlap (incl. touching-not-overlapping edges)

    func testConflictWhenRectsInterpenetrate() {
        let a = CGRect(x: 100, y: 100, width: 200, height: 200)
        let b = CGRect(x: 250, y: 250, width: 200, height: 200) // overlapping corner
        XCTAssertTrue(MonitorBoardLayoutEngine.conflicts(a, b))
    }

    func testEdgeSharingTilesDoNotConflict() {
        // Cell-exact neighbours share an edge exactly — legal, not a conflict.
        let a = CGRect(x: 100, y: 100, width: 200, height: 200)
        let b = CGRect(x: 300, y: 100, width: 200, height: 200) // shares a.maxX
        XCTAssertFalse(MonitorBoardLayoutEngine.conflicts(a, b))
        let below = CGRect(x: 100, y: 300, width: 200, height: 200) // shares a.maxY
        XCTAssertFalse(MonitorBoardLayoutEngine.conflicts(a, below))
    }

    func testSlightOverlapBeyondEpsilonConflicts() {
        let a = CGRect(x: 100, y: 100, width: 200, height: 200)
        // Overlap both axes by 2px (> epsilon) → conflict.
        let b = CGRect(x: 298, y: 298, width: 200, height: 200)
        XCTAssertTrue(MonitorBoardLayoutEngine.conflicts(a, b))
    }

    func testIsLegalRejectsOffBoard() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        let rect = CGRect(origin: CGPoint(x: -5, y: 300), size: footprint)
        XCTAssertFalse(MonitorBoardLayoutEngine.isLegal(rect: rect, geometry: g, items: [], ignoring: nil))
    }

    func testIsLegalIgnoresSelf() {
        let g = makeGeometry()
        let id = UUID()
        let footprint = g.pixelSize(for: .cpu, size: .medium)
        let origin = g.clampOrigin(CGPoint(x: 300, y: 300), footprint: footprint)
        let rect = CGRect(origin: origin, size: footprint)
        let items = [item(id, rect)]
        XCTAssertTrue(MonitorBoardLayoutEngine.isLegal(rect: rect, geometry: g, items: items, ignoring: id))
        XCTAssertFalse(MonitorBoardLayoutEngine.isLegal(rect: rect, geometry: g, items: items, ignoring: nil))
    }

    // MARK: - Magnetic snap

    func testSnapPicksNearestBoardEdgeWithinThreshold() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        // Origin a few px inside the left board edge → snaps to 0, emits guide.
        let free = CGPoint(x: 6, y: 400)
        let result = MonitorBoardLayoutEngine.snap(
            freeOrigin: free, footprint: footprint, geometry: g, items: [], ignoring: nil
        )
        XCTAssertTrue(result.snappedX)
        XCTAssertEqual(result.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(result.guideX?.position, 0)
        XCTAssertNil(result.guideX?.partner)
    }

    func testSnapDoesNotEngageBeyondThreshold() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        let centerX = (boardSize.width - footprint.width) / 2
        let free = CGPoint(x: centerX - (MonitorBoardLayoutEngine.snapThreshold + 30), y: 400)
        let result = MonitorBoardLayoutEngine.snap(
            freeOrigin: free, footprint: footprint, geometry: g, items: [], ignoring: nil
        )
        XCTAssertFalse(result.snappedX)
        XCTAssertEqual(result.origin.x, free.x, accuracy: 0.001)
    }

    func testSnapEdgeAlignsToSiblingLeftEdge() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        let siblingID = UUID()
        let sibling = CGRect(x: 500, y: 300, width: 200, height: 200)
        let items = [item(siblingID, sibling)]
        let free = CGPoint(x: sibling.minX + 5, y: 520)
        let result = MonitorBoardLayoutEngine.snap(
            freeOrigin: free, footprint: footprint, geometry: g, items: items, ignoring: nil
        )
        XCTAssertTrue(result.snappedX)
        XCTAssertEqual(result.origin.x, sibling.minX, accuracy: 0.001)
        XCTAssertEqual(result.guideX?.partner, sibling)
    }

    func testSnapFlushAdjacencyHasNoGuideLine() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        let siblingID = UUID()
        // At 10 columns the small-widget footprint is 160×160. Sibling at x=300
        // puts its flush-right edge at 500, clear of every board-edge / centre-line
        // x candidate (0, (1600-160)/2 = 720, 1600-160 = 1440), so the flush-right
        // snap — which carries NO guide — wins the x axis with guideX still nil.
        let sibling = CGRect(x: 300, y: 300, width: 200, height: 200)
        let items = [item(siblingID, sibling)]
        // Flush-right adjacency (cell-exact = sibling.maxX, no gutter). Keep the
        // dragged rect within the snap neighbourhood on y (offset the y just
        // enough that no edge-align y wins) so the flush-right x candidate — which
        // carries NO guide — is the winner on x.
        let adjacentX = sibling.maxX
        let free = CGPoint(x: adjacentX + 3, y: sibling.minY + 40)
        let result = MonitorBoardLayoutEngine.snap(
            freeOrigin: free, footprint: footprint, geometry: g, items: items, ignoring: nil
        )
        XCTAssertTrue(result.snappedX)
        XCTAssertEqual(result.origin.x, adjacentX, accuracy: 0.001)
        XCTAssertNil(result.guideX)
    }

    func testGuideSegmentMatchesSnappedEdge() throws {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        let siblingID = UUID()
        let sibling = CGRect(x: 500, y: 300, width: 200, height: 200)
        let items = [item(siblingID, sibling)]
        let free = CGPoint(x: sibling.minX + 4, y: 520)
        let result = MonitorBoardLayoutEngine.snap(
            freeOrigin: free, footprint: footprint, geometry: g, items: items, ignoring: nil
        )
        let guide = try XCTUnwrap(result.guideX)
        let draggedRect = CGRect(origin: result.origin, size: footprint)
        let seg = MonitorBoardLayoutEngine.guideSegment(guide, draggedRect: draggedRect, geometry: g)
        XCTAssertEqual(seg.start.x, sibling.minX, accuracy: 0.001)
        XCTAssertEqual(seg.end.x, sibling.minX, accuracy: 0.001)
        XCTAssertLessThanOrEqual(seg.start.y, min(draggedRect.minY, sibling.minY))
        XCTAssertGreaterThanOrEqual(seg.end.y, max(draggedRect.maxY, sibling.maxY))
    }

    func testBoardEdgeGuideSpansFullBoard() {
        let g = makeGeometry()
        let guide = MonitorSnapGuide(axis: .horizontal, position: 0, partner: nil)
        let seg = MonitorBoardLayoutEngine.guideSegment(
            guide, draggedRect: CGRect(x: 200, y: 0, width: 100, height: 100), geometry: g
        )
        XCTAssertEqual(seg.start.x, 0, accuracy: 0.001)
        XCTAssertEqual(seg.end.x, boardSize.width, accuracy: 0.001)
    }

    // MARK: - ⌘ bypass returns raw origin

    func testCommandBypassIsRawOrigin() throws {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        let free = CGPoint(x: 640, y: 480)
        let landed = try XCTUnwrap(MonitorBoardLayoutEngine.land(
            freeOrigin: free, snappedOrigin: nil, footprint: footprint,
            geometry: g, items: [], ignoring: nil
        ))
        XCTAssertEqual(landed.x, free.x, accuracy: 0.001)
        XCTAssertEqual(landed.y, free.y, accuracy: 0.001)
    }

    // MARK: - Overlap resolution

    func testResolvePassesThroughWhenAlreadyLegal() throws {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .cpu, size: .medium)
        let requested = g.clampOrigin(CGPoint(x: 400, y: 400), footprint: footprint)
        let resolved = try XCTUnwrap(MonitorBoardLayoutEngine.resolve(
            origin: requested, footprint: footprint, geometry: g,
            items: [], ignoring: nil, maxDisplacement: 1e9
        ))
        XCTAssertEqual(resolved.x, requested.x, accuracy: 0.001)
        XCTAssertEqual(resolved.y, requested.y, accuracy: 0.001)
    }

    func testResolveFindsAdjacentFreeSlotInCrowdedBoard() throws {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        let occupantID = UUID()
        let occupant = CGRect(origin: g.clampOrigin(CGPoint(x: 400, y: 400), footprint: footprint), size: footprint)
        let items = [item(occupantID, occupant)]

        let resolved = MonitorBoardLayoutEngine.resolve(
            origin: occupant.origin, footprint: footprint, geometry: g,
            items: items, ignoring: nil, maxDisplacement: 1e9
        )
        let resolvedPoint = try XCTUnwrap(resolved)
        let rect = CGRect(origin: resolvedPoint, size: footprint)
        XCTAssertTrue(MonitorBoardLayoutEngine.isLegal(rect: rect, geometry: g, items: items, ignoring: nil))
        XCTAssertFalse(MonitorBoardLayoutEngine.conflicts(rect, occupant))
        // Nearest free slot is flush-adjacent (cell-exact): exactly one footprint
        // over, on x OR y. Cells are square (160×160 on this 16:10 board), so the
        // x-shift and y-shift candidates tie exactly; the candidate search (x
        // outer, y inner, first-found-wins on ties) resolves the tie to a pure
        // y-shift (x unchanged).
        let dx = abs(resolvedPoint.x - occupant.origin.x)
        let dy = abs(resolvedPoint.y - occupant.origin.y)
        XCTAssertTrue(
            abs(dx - footprint.width) < 1.0 || abs(dy - footprint.height) < 1.0,
            "expected a flush one-footprint shift on x or y, got dx=\(dx) dy=\(dy)"
        )
    }

    func testResolveRejectsWhenNoSlotWithinMaxDisplacement() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        let occupantID = UUID()
        let occupant = CGRect(origin: g.clampOrigin(CGPoint(x: 400, y: 400), footprint: footprint), size: footprint)
        let items = [item(occupantID, occupant)]
        let resolved = MonitorBoardLayoutEngine.resolve(
            origin: occupant.origin, footprint: footprint, geometry: g,
            items: items, ignoring: nil, maxDisplacement: 1
        )
        XCTAssertNil(resolved)
    }

    func testResolveReturnsNilWhenBoardIsFull() {
        // A 10-column board is never full with a single widget, so tile it
        // wall-to-wall with small widgets; sizing the board so the small grid
        // tiles it wall-to-wall leaves no free slot for one more.
        let probe = MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 1000))
        let sfp = probe.pixelSize(for: .clock, size: .small)
        let exactBoard = CGSize(width: sfp.width * 6, height: sfp.height * 2)
        let g = MonitorBoardGeometry(boardSize: exactBoard)
        let items = fillBoard(g, kind: .clock, size: .small)
        let fp = g.pixelSize(for: .clock, size: .small)
        let resolved = MonitorBoardLayoutEngine.resolve(
            origin: CGPoint(x: exactBoard.width / 2, y: exactBoard.height / 2), footprint: fp,
            geometry: g, items: items, ignoring: nil, maxDisplacement: .greatestFiniteMagnitude
        )
        XCTAssertNil(resolved)
    }

    // MARK: - Drag landing

    func testLandPrefersSnappedOriginThenResolves() throws {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .clock, size: .small)
        let snapped = g.clampOrigin(CGPoint(x: 300, y: 300), footprint: footprint)
        let landed = try XCTUnwrap(MonitorBoardLayoutEngine.land(
            freeOrigin: CGPoint(x: 305, y: 305), snappedOrigin: snapped,
            footprint: footprint, geometry: g, items: [], ignoring: nil
        ))
        XCTAssertEqual(landed.x, snapped.x, accuracy: 0.001)
        XCTAssertEqual(landed.y, snapped.y, accuracy: 0.001)
    }

    func testLandSpringsBackWhenNoLegalSpotNearby() {
        // On a full board the drop target overlaps an occupant and every free
        // slot is beyond max displacement (max(dw,dh)) → land returns nil, so the
        // caller springs the widget back to its origin.
        let probe = MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 1000))
        let sfp = probe.pixelSize(for: .clock, size: .small)
        let exactBoard = CGSize(width: sfp.width * 6, height: sfp.height * 2)
        let g = MonitorBoardGeometry(boardSize: exactBoard)
        let items = fillBoard(g, kind: .clock, size: .small)
        let fp = g.pixelSize(for: .clock, size: .small)
        // Aim at an occupied cell centre.
        let target = CGPoint(x: exactBoard.width / 2 - fp.width / 2, y: exactBoard.height / 2 - fp.height / 2)
        let landed = MonitorBoardLayoutEngine.land(
            freeOrigin: target, snappedOrigin: target,
            footprint: fp, geometry: g, items: items, ignoring: nil
        )
        XCTAssertNil(landed)
    }

    // MARK: - Size toggle re-fit

    func testSizeToggleKeepsAnchorWhenItFits() throws {
        let g = makeGeometry()
        let anchor = g.clampOrigin(CGPoint(x: 300, y: 300), footprint: g.pixelSize(for: .cpu, size: .small))
        let newFootprint = g.pixelSize(for: .cpu, size: .medium)
        let refit = try XCTUnwrap(MonitorBoardLayoutEngine.refitForSizeChange(
            anchor: anchor, newFootprint: newFootprint, geometry: g, items: [], ignoring: nil
        ))
        XCTAssertEqual(refit.x, anchor.x, accuracy: 0.001)
        XCTAssertEqual(refit.y, anchor.y, accuracy: 0.001)
    }

    func testSizeToggleShiftsLeftWhenMediumOverhangsRightEdge() throws {
        let g = makeGeometry()
        let mediumFootprint = g.pixelSize(for: .cpu, size: .medium)
        let smallFootprint = g.pixelSize(for: .cpu, size: .small)
        // Anchor a small widget flush against the right board edge, then grow to
        // M: the M footprint overhangs, so refit shifts left, staying on-board.
        let anchor = g.clampOrigin(CGPoint(x: boardSize.width, y: 300), footprint: smallFootprint)
        let refit = try XCTUnwrap(MonitorBoardLayoutEngine.refitForSizeChange(
            anchor: anchor, newFootprint: mediumFootprint, geometry: g, items: [], ignoring: nil
        ))
        XCTAssertLessThan(refit.x, anchor.x)
        let rect = CGRect(origin: refit, size: mediumFootprint)
        XCTAssertLessThanOrEqual(rect.maxX, boardSize.width + MonitorBoardLayoutEngine.epsilon)
        XCTAssertTrue(MonitorBoardLayoutEngine.isLegal(rect: rect, geometry: g, items: [], ignoring: nil))
    }

    func testSizeToggleRejectsWhenNoRoomForLargerFootprint() {
        // Board sized to a tight grid of small widgets so no medium slot fits.
        let g0 = MonitorBoardGeometry(boardSize: CGSize(width: 480, height: 900))
        let small0 = g0.pixelSize(for: .cpu, size: .small)
        // Make the board an exact multiple of small footprints.
        let cols = 2, rowsCount = 4
        let tightBoard = CGSize(width: small0.width * CGFloat(cols), height: small0.height * CGFloat(rowsCount))
        let g = MonitorBoardGeometry(boardSize: tightBoard)
        let small = g.pixelSize(for: .cpu, size: .small)
        let medium = g.pixelSize(for: .cpu, size: .medium)
        var items: [MonitorBoardItem] = []
        var y: CGFloat = 0
        while y + small.height <= tightBoard.height + 0.5 {
            var x: CGFloat = 0
            while x + small.width <= tightBoard.width + 0.5 {
                items.append(item(UUID(), CGRect(x: x, y: y, width: small.width, height: small.height)))
                x += small.width
            }
            y += small.height
        }
        let anchor = items.first!.rect.origin
        let refit = MonitorBoardLayoutEngine.refitForSizeChange(
            anchor: anchor, newFootprint: medium, geometry: g,
            items: items, ignoring: items.first!.id
        )
        XCTAssertNil(refit)
    }

    // MARK: - Add-widget first fit

    func testFirstFitPlacesInLowerCentreOnEmptyBoard() throws {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .cpu, size: .medium)
        let fit = try XCTUnwrap(MonitorBoardLayoutEngine.firstFit(footprint: footprint, geometry: g, items: []))
        let rect = CGRect(origin: fit, size: footprint)
        XCTAssertTrue(MonitorBoardLayoutEngine.isLegal(rect: rect, geometry: g, items: [], ignoring: nil))
        let centerX = (boardSize.width - footprint.width) / 2
        XCTAssertEqual(rect.minX, centerX, accuracy: g.cellWidth)
        XCTAssertGreaterThan(rect.midY, boardSize.height * 0.5)
    }

    func testFirstFitAvoidsExistingWidgets() throws {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .cpu, size: .medium)
        let target = CGPoint(x: (boardSize.width - footprint.width) / 2, y: boardSize.height * 0.64)
        let occupied = g.clampOrigin(target, footprint: footprint)
        let items = [item(UUID(), CGRect(origin: occupied, size: footprint))]
        let fit = try XCTUnwrap(MonitorBoardLayoutEngine.firstFit(footprint: footprint, geometry: g, items: items))
        let rect = CGRect(origin: fit, size: footprint)
        XCTAssertTrue(MonitorBoardLayoutEngine.isLegal(rect: rect, geometry: g, items: items, ignoring: nil))
    }

    func testFirstFitReturnsNilWhenBoardFull() {
        let probe = MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 1000))
        let sfp = probe.pixelSize(for: .clock, size: .small)
        let exactBoard = CGSize(width: sfp.width * 6, height: sfp.height * 2)
        let g = MonitorBoardGeometry(boardSize: exactBoard)
        let items = fillBoard(g, kind: .clock, size: .small)
        let fp = g.pixelSize(for: .clock, size: .small)
        XCTAssertNil(MonitorBoardLayoutEngine.firstFit(footprint: fp, geometry: g, items: items))
    }

    // MARK: - No-overlap invariant on the default preset

    func testDefaultSystemPlacementsLegalizeWithoutOverlap() throws {
        // `packedPlacements` stores cell-exact normalized coords against a 16:10
        // *reference* row-height; on a board whose aspect differs, the pixel
        // footprint heights won't match the normalized row spacing, so raw
        // placements can overlap. The engine's legalization (what `reflow` runs)
        // resolves each onto the nearest free slot — this asserts that pass ends
        // overlap-free with every widget still placed.
        let g = makeGeometry()
        let placements = MonitorBoardConfiguration.defaultSystemPlacements()
        var items: [MonitorBoardItem] = []
        for placement in placements {
            let footprint = g.pixelSize(for: placement.kind, size: placement.size)
            let origin = MonitorBoardLayoutEngine.pixelOrigin(
                normalized: CGPoint(x: placement.x, y: placement.y), boardSize: boardSize
            )
            let resolved = try XCTUnwrap(
                MonitorBoardLayoutEngine.resolve(
                    origin: origin, footprint: footprint, geometry: g,
                    items: items, ignoring: nil, maxDisplacement: .greatestFiniteMagnitude
                ),
                "default placement \(placement.kind) should legalize onto the board"
            )
            items.append(item(placement.id, CGRect(origin: resolved, size: footprint)))
        }
        for i in 0..<items.count {
            for j in (i + 1)..<items.count {
                XCTAssertFalse(
                    MonitorBoardLayoutEngine.conflicts(items[i].rect, items[j].rect),
                    "legalized default placements \(i) and \(j) overlap"
                )
            }
        }
    }
}
