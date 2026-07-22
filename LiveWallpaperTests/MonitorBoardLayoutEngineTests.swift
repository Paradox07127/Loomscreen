import CoreGraphics
import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

final class MonitorBoardLayoutEngineTests: XCTestCase {

    private let boardSize = CGSize(width: 1600, height: 1000)

    private func makeGeometry() -> MonitorBoardGeometry {
        MonitorBoardGeometry(boardSize: boardSize)
    }

    private func item(_ id: UUID, _ rect: CGRect) -> MonitorBoardItem {
        MonitorBoardItem(id: id, rect: rect)
    }

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

    func testFixedApplePitchIndependentOfBoardWidth() {
        let g = makeGeometry()
        XCTAssertEqual(g.cellWidth, 194, accuracy: 0.001)
        XCTAssertEqual(g.cellHeight, 206, accuracy: 0.001)
        XCTAssertEqual(g.tileInsetX, 12, accuracy: 0.001)
        XCTAssertEqual(g.tileInsetY, 18, accuracy: 0.001)
        XCTAssertEqual(g.columns, 8)

        let huge = MonitorBoardGeometry(boardSize: CGSize(width: 3000, height: 1875))
        XCTAssertEqual(huge.cellWidth, 194, accuracy: 0.001)
        XCTAssertEqual(huge.cellHeight, 206, accuracy: 0.001)
        XCTAssertEqual(huge.columns, 15)
    }

    func testRenderedFramesMatchAppleWidgetSizes() {
        let g = makeGeometry()
        let s = g.renderRect(forRawRect: CGRect(origin: .zero, size: g.pixelSize(for: .memory, size: .small)))
        XCTAssertEqual(s.width, 170, accuracy: 0.001)
        XCTAssertEqual(s.height, 170, accuracy: 0.001)
        let m = g.renderRect(forRawRect: CGRect(origin: .zero, size: g.pixelSize(for: .cpu, size: .medium)))
        XCTAssertEqual(m.width, 364, accuracy: 0.001)
        XCTAssertEqual(m.height, 170, accuracy: 0.001)
        let l = g.renderRect(forRawRect: CGRect(origin: .zero, size: g.pixelSize(for: .cpu, size: .large)))
        XCTAssertEqual(l.width, 364, accuracy: 0.001)
        XCTAssertEqual(l.height, 376, accuracy: 0.001)
    }

    func testReferenceWidthScalesMetricsForPreview() {
        let g = MonitorBoardGeometry(
            boardSize: CGSize(width: 400, height: 250), referenceWidth: 1600
        )
        XCTAssertEqual(g.cellWidth, 194 * 0.25, accuracy: 0.001)
        XCTAssertEqual(g.cellHeight, 206 * 0.25, accuracy: 0.001)
        XCTAssertEqual(g.tileInsetX, 12 * 0.25, accuracy: 0.001)
        XCTAssertEqual(g.tileInsetY, 18 * 0.25, accuracy: 0.001)
        XCTAssertEqual(g.columns, MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 1000)).columns)
    }

    func testFootprintIsPureCellMultiple() {
        let g = makeGeometry()
        let medium = g.pixelSize(for: .cpu, size: .medium)
        XCTAssertEqual(medium.width, 2 * g.cellWidth, accuracy: 0.001)
        XCTAssertEqual(medium.height, 1 * g.cellHeight, accuracy: 0.001)
        let small = g.pixelSize(for: .memory, size: .small)
        XCTAssertEqual(small.width, 1 * g.cellWidth, accuracy: 0.001)
        XCTAssertEqual(small.height, 1 * g.cellHeight, accuracy: 0.001)
    }

    func testRenderRectInsetsForGutter() {
        let g = makeGeometry()
        let raw = CGRect(x: 100, y: 100, width: 400, height: 200)
        let rendered = g.renderRect(forRawRect: raw)
        XCTAssertEqual(rendered.minX, raw.minX + g.tileInsetX, accuracy: 0.001)
        XCTAssertEqual(rendered.minY, raw.minY + g.tileInsetY, accuracy: 0.001)
        XCTAssertEqual(rendered.width, raw.width - 2 * g.tileInsetX, accuracy: 0.001)
        XCTAssertEqual(rendered.height, raw.height - 2 * g.tileInsetY, accuracy: 0.001)
        let rawRight = CGRect(x: raw.maxX, y: 100, width: 400, height: 200)
        let renderedRight = g.renderRect(forRawRect: rawRight)
        XCTAssertEqual(renderedRight.minX - rendered.maxX, 24, accuracy: 0.001)
        let rawBelow = CGRect(x: 100, y: raw.maxY, width: 400, height: 200)
        let renderedBelow = g.renderRect(forRawRect: rawBelow)
        XCTAssertEqual(renderedBelow.minY - rendered.maxY, 36, accuracy: 0.001)
    }

    func testDegenerateBoardFlagged() {
        XCTAssertTrue(MonitorBoardGeometry(boardSize: .zero).isDegenerate)
        XCTAssertFalse(makeGeometry().isDegenerate)
    }

    func testReferenceRowAndColumnCounts() {
        let g1610 = MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(g1610.columns, 8)
        XCTAssertEqual(g1610.rows, 4)

        let g169 = MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 900))
        XCTAssertEqual(g169.rows, 4)

        let gWide = MonitorBoardGeometry(boardSize: CGSize(width: 1200, height: 400))
        XCTAssertEqual(gWide.columns, 6)
        XCTAssertEqual(gWide.rows, 1)

        let gPortrait = MonitorBoardGeometry(boardSize: CGSize(width: 900, height: 1600))
        XCTAssertEqual(gPortrait.columns, 4)
        XCTAssertEqual(gPortrait.rows, 7)
    }

    func testCornerRadiusIsAppleRadiusScaled() {
        let live = makeGeometry()
        XCTAssertEqual(live.cornerRadius, 16, accuracy: 0.001)

        let preview = MonitorBoardGeometry(
            boardSize: CGSize(width: 400, height: 250), referenceWidth: 1600
        )
        XCTAssertEqual(preview.cornerRadius, 4, accuracy: 0.001)
    }

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
        let cellX = 3 * g.cellWidth
        let normalized = MonitorBoardLayoutEngine.normalized(
            pixelOrigin: CGPoint(x: cellX, y: 0), boardSize: boardSize
        )
        let px = MonitorBoardLayoutEngine.pixelOrigin(normalized: normalized, boardSize: boardSize)
        XCTAssertEqual(px.x, cellX, accuracy: 0.001)
    }

    func testNormalizedOnZeroBoardIsOrigin() {
        let back = MonitorBoardLayoutEngine.normalized(pixelOrigin: CGPoint(x: 42, y: 42), boardSize: .zero)
        XCTAssertEqual(back, .zero)
    }

    func testClampPinsFootprintOnBoardAtEdges() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .cpu, size: .medium)

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

    private func insetGeometry() -> MonitorBoardGeometry {
        MonitorBoardGeometry(boardSize: boardSize, topInsetFraction: 0.05)
    }

    func testTopInsetStoredAsPixels() {
        XCTAssertEqual(insetGeometry().topInset, 50, accuracy: 0.001)
        XCTAssertEqual(makeGeometry().topInset, 0, accuracy: 0.001)
    }

    func testTopInsetClampsOriginDownToInsetLine() {
        let g = insetGeometry()
        let footprint = g.pixelSize(for: .memory, size: .small)
        let clamped = g.clampOrigin(CGPoint(x: 200, y: 0), footprint: footprint)
        XCTAssertEqual(clamped.y, 50, accuracy: 0.001)
        let below = g.clampOrigin(CGPoint(x: 200, y: 300), footprint: footprint)
        XCTAssertEqual(below.y, 300, accuracy: 0.001)
    }

    func testTopInsetRejectsRectIntrudingIntoZone() {
        let g = insetGeometry()
        let footprint = g.pixelSize(for: .memory, size: .small)
        let intruding = CGRect(origin: CGPoint(x: 200, y: 20), size: footprint)
        XCTAssertFalse(MonitorBoardLayoutEngine.isLegal(rect: intruding, geometry: g, items: [], ignoring: nil))
        let onLine = CGRect(origin: CGPoint(x: 200, y: 50), size: footprint)
        XCTAssertTrue(MonitorBoardLayoutEngine.isLegal(rect: onLine, geometry: g, items: [], ignoring: nil))
    }

    func testTopInsetMovesTopSnapCandidateToInsetLine() {
        let g = insetGeometry()
        let footprint = g.pixelSize(for: .memory, size: .small)
        let free = CGPoint(x: 400, y: 54)
        let result = MonitorBoardLayoutEngine.snap(
            freeOrigin: free, footprint: footprint, geometry: g, items: [], ignoring: nil
        )
        XCTAssertTrue(result.snappedY)
        XCTAssertEqual(result.origin.y, 50, accuracy: 0.001)
        XCTAssertEqual(result.guideY?.position, 50)
    }

    func testConflictWhenRectsInterpenetrate() {
        let a = CGRect(x: 100, y: 100, width: 200, height: 200)
        let b = CGRect(x: 250, y: 250, width: 200, height: 200)
        XCTAssertTrue(MonitorBoardLayoutEngine.conflicts(a, b))
    }

    func testEdgeSharingTilesDoNotConflict() {
        let a = CGRect(x: 100, y: 100, width: 200, height: 200)
        let b = CGRect(x: 300, y: 100, width: 200, height: 200)
        XCTAssertFalse(MonitorBoardLayoutEngine.conflicts(a, b))
        let below = CGRect(x: 100, y: 300, width: 200, height: 200)
        XCTAssertFalse(MonitorBoardLayoutEngine.conflicts(a, below))
    }

    func testSlightOverlapBeyondEpsilonConflicts() {
        let a = CGRect(x: 100, y: 100, width: 200, height: 200)
        let b = CGRect(x: 298, y: 298, width: 200, height: 200)
        XCTAssertTrue(MonitorBoardLayoutEngine.conflicts(a, b))
    }

    func testIsLegalRejectsOffBoard() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .memory, size: .small)
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

    func testSnapPicksNearestBoardEdgeWithinThreshold() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .memory, size: .small)
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
        let footprint = g.pixelSize(for: .memory, size: .small)
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
        let footprint = g.pixelSize(for: .memory, size: .small)
        let siblingID = UUID()
        let sibling = CGRect(x: 500, y: 300, width: 200, height: 200)
        let items = [item(siblingID, sibling)]
        let free = CGPoint(x: sibling.minX + 1, y: 520)
        let result = MonitorBoardLayoutEngine.snap(
            freeOrigin: free, footprint: footprint, geometry: g, items: items, ignoring: nil
        )
        XCTAssertTrue(result.snappedX)
        XCTAssertEqual(result.origin.x, sibling.minX, accuracy: 0.001)
        XCTAssertEqual(result.guideX?.partner, sibling)
    }

    func testSnapFlushAdjacencyHasNoGuideLine() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .memory, size: .small)
        let siblingID = UUID()
        let sibling = CGRect(x: 300, y: 300, width: 200, height: 200)
        let items = [item(siblingID, sibling)]
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
        let footprint = g.pixelSize(for: .memory, size: .small)
        let siblingID = UUID()
        let sibling = CGRect(x: 500, y: 300, width: 200, height: 200)
        let items = [item(siblingID, sibling)]
        let free = CGPoint(x: sibling.minX + 1, y: 520)
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

    func testCommandBypassIsRawOrigin() throws {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .memory, size: .small)
        let free = CGPoint(x: 640, y: 480)
        let landed = try XCTUnwrap(MonitorBoardLayoutEngine.land(
            freeOrigin: free, snappedOrigin: nil, footprint: footprint,
            geometry: g, items: [], ignoring: nil
        ))
        XCTAssertEqual(landed.x, free.x, accuracy: 0.001)
        XCTAssertEqual(landed.y, free.y, accuracy: 0.001)
    }

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
        let footprint = g.pixelSize(for: .memory, size: .small)
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
        let dx = abs(resolvedPoint.x - occupant.origin.x)
        let dy = abs(resolvedPoint.y - occupant.origin.y)
        XCTAssertTrue(
            abs(dx - footprint.width) < 1.0 || abs(dy - footprint.height) < 1.0,
            "expected a flush one-footprint shift on x or y, got dx=\(dx) dy=\(dy)"
        )
    }

    func testResolveRejectsWhenNoSlotWithinMaxDisplacement() {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .memory, size: .small)
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
        let probe = MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 1000))
        let sfp = probe.pixelSize(for: .memory, size: .small)
        let exactBoard = CGSize(width: sfp.width * 6, height: sfp.height * 2)
        let g = MonitorBoardGeometry(boardSize: exactBoard)
        let items = fillBoard(g, kind: .memory, size: .small)
        let fp = g.pixelSize(for: .memory, size: .small)
        let resolved = MonitorBoardLayoutEngine.resolve(
            origin: CGPoint(x: exactBoard.width / 2, y: exactBoard.height / 2), footprint: fp,
            geometry: g, items: items, ignoring: nil, maxDisplacement: .greatestFiniteMagnitude
        )
        XCTAssertNil(resolved)
    }

    func testLandPrefersSnappedOriginThenResolves() throws {
        let g = makeGeometry()
        let footprint = g.pixelSize(for: .memory, size: .small)
        let snapped = g.clampOrigin(CGPoint(x: 300, y: 300), footprint: footprint)
        let landed = try XCTUnwrap(MonitorBoardLayoutEngine.land(
            freeOrigin: CGPoint(x: 305, y: 305), snappedOrigin: snapped,
            footprint: footprint, geometry: g, items: [], ignoring: nil
        ))
        XCTAssertEqual(landed.x, snapped.x, accuracy: 0.001)
        XCTAssertEqual(landed.y, snapped.y, accuracy: 0.001)
    }

    func testLandSpringsBackWhenNoLegalSpotNearby() {
        let probe = MonitorBoardGeometry(boardSize: CGSize(width: 1600, height: 1000))
        let sfp = probe.pixelSize(for: .memory, size: .small)
        let exactBoard = CGSize(width: sfp.width * 6, height: sfp.height * 2)
        let g = MonitorBoardGeometry(boardSize: exactBoard)
        let items = fillBoard(g, kind: .memory, size: .small)
        let fp = g.pixelSize(for: .memory, size: .small)
        let target = CGPoint(x: exactBoard.width / 2 - fp.width / 2, y: exactBoard.height / 2 - fp.height / 2)
        let landed = MonitorBoardLayoutEngine.land(
            freeOrigin: target, snappedOrigin: target,
            footprint: fp, geometry: g, items: items, ignoring: nil
        )
        XCTAssertNil(landed)
    }

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
        let g0 = MonitorBoardGeometry(boardSize: CGSize(width: 480, height: 900))
        let small0 = g0.pixelSize(for: .cpu, size: .small)
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
        let sfp = probe.pixelSize(for: .memory, size: .small)
        let exactBoard = CGSize(width: sfp.width * 6, height: sfp.height * 2)
        let g = MonitorBoardGeometry(boardSize: exactBoard)
        let items = fillBoard(g, kind: .memory, size: .small)
        let fp = g.pixelSize(for: .memory, size: .small)
        XCTAssertNil(MonitorBoardLayoutEngine.firstFit(footprint: fp, geometry: g, items: items))
    }

    func testDefaultSystemPlacementsLegalizeWithoutOverlap() throws {
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
