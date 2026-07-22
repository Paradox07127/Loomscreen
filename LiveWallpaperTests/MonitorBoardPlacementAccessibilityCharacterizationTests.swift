import CoreGraphics
import Foundation
@testable import LiveWallpaper
@testable import LiveWallpaperCore
import Testing

/// Pins shared pointer, keyboard, and accessibility semantics without requiring a hidden-window AX hierarchy.
@Suite("Monitor board placement and accessibility characterization")
struct MonitorBoardPlacementAccessibilityCharacterizationTests {
    private let boardSize = CGSize(width: 1600, height: 1000)

    @Test("drag updates one placement in place without changing identity or order")
    @MainActor
    func dragPreservesIdentityAndArrayOrder() throws {
        let movedID = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let siblingID = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        let moved = MonitorWidgetPlacement(
            id: movedID,
            kind: .cpu,
            size: .medium,
            x: 0.10,
            y: 0.10,
            options: ["fixture": .string("preserved")]
        )
        let sibling = MonitorWidgetPlacement(
            id: siblingID,
            kind: .memory,
            size: .small,
            x: 0.75,
            y: 0.10
        )
        let model = makeModel(placements: [moved, sibling])
        var emissions: [MonitorBoardConfiguration] = []
        model.onConfigurationEdited = { emissions.append($0) }

        model.beginDrag(movedID, grabOffset: .zero)
        model.updateDrag(pointInBoard: CGPoint(x: 720, y: 600), bypassSnap: true)
        model.endDrag(bypassSnap: true)

        #expect(model.placements.map(\.id) == [movedID, siblingID])
        let landed = try #require(model.placements.first)
        #expect(landed.id == moved.id)
        #expect(landed.kind == moved.kind)
        #expect(landed.size == moved.size)
        #expect(landed.options == moved.options)
        #expect(isApproximatelyEqual(landed.x, 0.45))
        #expect(isApproximatelyEqual(landed.y, 0.60))
        #expect(model.placements[1] == sibling)
        #expect(emissions.count == 1)
        #expect(emissions.first?.widgets == model.placements)
    }

    @Test("drag landing clamps the full footprint then persists a normalized top-left")
    @MainActor
    func dragClampsAndNormalizesCoordinates() throws {
        let id = try #require(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        let placement = MonitorWidgetPlacement(
            id: id,
            kind: .network,
            size: .small,
            x: 0.20,
            y: 0.20
        )
        let model = makeModel(placements: [placement])
        model.topInsetFraction = 0.05
        var emissions: [MonitorBoardConfiguration] = []
        model.onConfigurationEdited = { emissions.append($0) }

        model.beginDrag(id, grabOffset: .zero)
        model.updateDrag(pointInBoard: CGPoint(x: 5000, y: -5000), bypassSnap: true)
        model.endDrag(bypassSnap: true)

        let landed = try #require(model.placements.first)
        let footprint = model.geometry.pixelSize(for: landed.kind, size: landed.size)
        let expectedPixelOrigin = CGPoint(
            x: boardSize.width - footprint.width,
            y: boardSize.height * model.topInsetFraction
        )
        let expectedNormalized = MonitorBoardLayoutEngine.normalized(
            pixelOrigin: expectedPixelOrigin,
            boardSize: boardSize
        )

        #expect(landed.id == id)
        #expect(isApproximatelyEqual(landed.x, expectedNormalized.x))
        #expect(isApproximatelyEqual(landed.y, expectedNormalized.y))
        #expect((0 ... 1).contains(landed.x))
        #expect((0 ... 1).contains(landed.y))
        #expect(emissions.count == 1)
    }

    @Test("a click-sized drag does not rewrite placement or emit configuration")
    @MainActor
    func clickSizedDragIsNotAPlacementEdit() throws {
        let id = try #require(UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
        let placement = MonitorWidgetPlacement(
            id: id,
            kind: .disk,
            size: .small,
            x: 0.25,
            y: 0.30
        )
        let model = makeModel(placements: [placement])
        var emissions = 0
        model.onConfigurationEdited = { _ in emissions += 1 }
        let origin = model.pixelOrigin(for: placement)

        model.beginDrag(id, grabOffset: .zero)
        model.updateDrag(
            pointInBoard: CGPoint(x: origin.x + 3, y: origin.y),
            bypassSnap: true
        )
        model.endDrag(bypassSnap: true)

        #expect(model.placements == [placement])
        #expect(emissions == 0)
    }

    @Test("delete removes exactly one identity and preserves sibling order")
    @MainActor
    func deletePreservesSurvivingOrder() throws {
        let firstID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let removedID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let lastID = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let placements = [
            MonitorWidgetPlacement(id: firstID, kind: .cpu, size: .small, x: 0.1, y: 0.1),
            MonitorWidgetPlacement(id: removedID, kind: .memory, size: .small, x: 0.3, y: 0.1),
            MonitorWidgetPlacement(id: lastID, kind: .gpu, size: .small, x: 0.5, y: 0.1),
        ]
        let model = makeModel(placements: placements)
        model.selectedID = removedID
        model.settingsOpenID = removedID
        var emissions: [MonitorBoardConfiguration] = []
        model.onConfigurationEdited = { emissions.append($0) }

        #expect(model.perform(.delete(id: removedID)))

        #expect(model.placements == [placements[0], placements[2]])
        #expect(model.placements.map(\.id) == [firstID, lastID])
        #expect(model.selectedID == nil)
        #expect(model.settingsOpenID == nil)
        #expect(emissions.count == 1)
        #expect(emissions.first?.widgets == [placements[0], placements[2]])

        #expect(!model.perform(.delete(id: removedID)))
        #expect(model.placements == [placements[0], placements[2]])
        #expect(emissions.count == 1)
    }

    @Test("keyboard move uses the shared placement command and keeps normalized coordinates")
    @MainActor
    func keyboardMoveUsesSharedCommand() throws {
        let movedID = try #require(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let siblingID = try #require(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        let moved = MonitorWidgetPlacement(
            id: movedID,
            kind: .cpu,
            size: .small,
            x: 0.10,
            y: 0.20,
            options: ["fixture": .string("preserved")]
        )
        let sibling = MonitorWidgetPlacement(
            id: siblingID,
            kind: .memory,
            size: .small,
            x: 0.75,
            y: 0.20
        )
        let model = makeModel(placements: [moved, sibling])
        model.selectedID = movedID
        var emissions: [MonitorBoardConfiguration] = []
        model.onConfigurationEdited = { emissions.append($0) }

        #expect(model.moveSelectedWidget(.right, distance: 25))

        #expect(model.placements.map(\.id) == [movedID, siblingID])
        let landed = try #require(model.placements.first)
        #expect(landed.kind == moved.kind)
        #expect(landed.size == moved.size)
        #expect(landed.options == moved.options)
        #expect(isApproximatelyEqual(landed.x, moved.x + 25 / boardSize.width))
        #expect(isApproximatelyEqual(landed.y, moved.y))
        #expect(model.placements[1] == sibling)
        #expect(emissions.count == 1)
        #expect(emissions.first?.widgets == model.placements)
    }

    @Test("targeted accessibility move is edit-gated and does not change selection")
    @MainActor
    func targetedAccessibilityMoveUsesItsPlacementID() throws {
        let selectedID = try #require(UUID(uuidString: "A1111111-1111-1111-1111-111111111111"))
        let targetID = try #require(UUID(uuidString: "B2222222-2222-2222-2222-222222222222"))
        let selected = MonitorWidgetPlacement(
            id: selectedID, kind: .cpu, size: .small, x: 0.10, y: 0.20
        )
        let target = MonitorWidgetPlacement(
            id: targetID, kind: .memory, size: .small, x: 0.50, y: 0.20
        )
        let model = makeModel(placements: [selected, target])
        model.selectedID = selectedID
        var emissions = 0
        model.onConfigurationEdited = { _ in emissions += 1 }

        #expect(model.moveWidget(id: targetID, direction: .right, distance: 25))
        #expect(model.selectedID == selectedID)
        #expect(model.placements[0] == selected)
        #expect(isApproximatelyEqual(model.placements[1].x, target.x + 25 / boardSize.width))
        #expect(emissions == 1)

        model.setEditing(false)
        #expect(!model.moveWidget(id: targetID, direction: .right, distance: 25))
        #expect(model.selectedID == nil)
        #expect(isApproximatelyEqual(model.placements[1].x, target.x + 25 / boardSize.width))
        #expect(emissions == 1)
    }

    @Test("keyboard move clamps the full footprint below the top inset")
    @MainActor
    func keyboardMoveClampsFootprintAndTopInset() throws {
        let id = try #require(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let placement = MonitorWidgetPlacement(
            id: id,
            kind: .network,
            size: .medium,
            x: 0.90,
            y: 0.01
        )
        let model = makeModel(placements: [placement])
        model.topInsetFraction = 0.05
        model.selectedID = id

        #expect(model.moveSelectedWidget(.right, distance: 5000))
        #expect(!model.moveSelectedWidget(.up, distance: 5000))

        let landed = try #require(model.placements.first)
        let footprint = model.footprint(for: landed)
        let origin = model.pixelOrigin(for: landed)
        #expect(isApproximatelyEqual(origin.x, boardSize.width - footprint.width))
        #expect(isApproximatelyEqual(origin.y, boardSize.height * model.topInsetFraction))
        #expect((0 ... 1).contains(landed.x))
        #expect((0 ... 1).contains(landed.y))
    }

    @Test("keyboard delete requires edit mode and removes only the selected identity")
    @MainActor
    func keyboardDeleteIsTargetOnly() throws {
        let firstID = try #require(UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        let targetID = try #require(UUID(uuidString: "88888888-8888-8888-8888-888888888888"))
        let lastID = try #require(UUID(uuidString: "99999999-9999-9999-9999-999999999999"))
        let placements = [
            MonitorWidgetPlacement(id: firstID, kind: .cpu, size: .small, x: 0.1, y: 0.1),
            MonitorWidgetPlacement(id: targetID, kind: .memory, size: .small, x: 0.3, y: 0.1),
            MonitorWidgetPlacement(id: lastID, kind: .gpu, size: .small, x: 0.5, y: 0.1),
        ]
        let model = makeModel(placements: placements)
        model.selectedID = targetID
        model.setEditing(false)

        #expect(!model.deleteSelectedWidget())
        #expect(model.placements == placements)

        model.setEditing(true)
        model.selectedID = targetID
        #expect(model.deleteSelectedWidget())
        #expect(model.placements == [placements[0], placements[2]])
        #expect(model.placements.map(\.id) == [firstID, lastID])
    }

    @Test("pointer, keyboard, and accessibility edits route through one command executor")
    func sharedPlacementCommandSourceContract() throws {
        let interaction = try source("LiveWallpaper/Monitor/Board/MonitorBoardInteractionModel.swift")
        let chrome = try source("LiveWallpaper/Monitor/Board/MonitorBoardEditChrome.swift")
        let root = try source("LiveWallpaper/Monitor/Board/MonitorBoardRootView.swift")

        #expect(interaction.contains("@Published private(set) var placements"))
        #expect(interaction.contains("enum MonitorBoardPlacementCommand"))
        #expect(interaction.contains("func perform(_ command: MonitorBoardPlacementCommand)"))
        #expect(interaction.contains("MonitorBoardLayoutEngine.land("))
        #expect(interaction.contains("MonitorBoardLayoutEngine.normalized("))
        #expect(interaction.contains("perform(.move(id: current.widgetID"))
        #expect(interaction.contains("func moveWidget("))
        #expect(interaction.contains("return moveWidget(id: selectedID, direction: direction, distance: distance)"))
        #expect(interaction.contains("return perform(.move("))
        #expect(interaction.contains("return perform(.delete(id: selectedID))"))
        #expect(chrome.contains("model.beginDrag(placement.id"))
        #expect(chrome.contains("model.updateDrag(pointInBoard:"))
        #expect(chrome.contains("model.endDrag(bypassSnap:"))
        #expect(chrome.components(separatedBy: "model.perform(.delete(id: placement.id))").count - 1 == 2)
        #expect(root.contains(".onMoveCommand(perform: handleMoveCommand)"))
        #expect(root.contains(".onDeleteCommand"))
        #expect(root.contains("model.moveSelectedWidget("))
        #expect(root.contains("model.deleteSelectedWidget()"))
    }

    @Test("keyboard focus and target-specific VoiceOver placement actions are production entry points")
    func accessibilityEntryPointSourceContract() throws {
        let root = try source("LiveWallpaper/Monitor/Board/MonitorBoardRootView.swift")
        let chrome = try source("LiveWallpaper/Monitor/Board/MonitorBoardEditChrome.swift")
        let interaction = try source("LiveWallpaper/Monitor/Board/MonitorBoardInteractionModel.swift")
        let boardUI = root + "\n" + chrome

        #expect(boardUI.contains(".focusable(model.isEditing)"))
        #expect(boardUI.contains(".focused($boardFocused)"))
        #expect(boardUI.contains(".accessibilityAction(named:"))
        #expect(chrome.contains("if model.isEditing"))
        #expect(chrome.contains("MonitorBoardStrings.moveLeft"))
        #expect(chrome.contains("MonitorBoardStrings.moveRight"))
        #expect(chrome.contains("MonitorBoardStrings.moveUp"))
        #expect(chrome.contains("MonitorBoardStrings.moveDown"))
        #expect(chrome.contains("model.moveWidget(id: placementID, direction: .left)"))
        #expect(chrome.contains("model.moveWidget(id: placementID, direction: .right)"))
        #expect(chrome.contains("model.moveWidget(id: placementID, direction: .up)"))
        #expect(chrome.contains("model.moveWidget(id: placementID, direction: .down)"))
        #expect(chrome.contains("model.perform(.delete(id: placementID))"))
        #expect(interaction.contains("case delete(id: UUID)"))
    }

    @MainActor
    private func makeModel(
        placements: [MonitorWidgetPlacement]
    ) -> MonitorBoardInteractionModel {
        let model = MonitorBoardInteractionModel(
            configuration: MonitorBoardConfiguration(
                widgets: placements,
                refreshHz: 1.5,
                mouseInteractionEnabled: true,
                reduceMotionOverride: false
            ),
            isAgentFleetEnabled: true
        )
        model.boardSize = boardSize
        model.setEditing(true)
        return model
    }

    private func isApproximatelyEqual(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double = 1e-9
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private func source(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
