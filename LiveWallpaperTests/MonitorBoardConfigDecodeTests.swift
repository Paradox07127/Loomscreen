import Foundation
import Testing
@testable import LiveWallpaperCore

/// Covers the Monitor board config at the `WallpaperContent` / `ScreenConfiguration`
/// persistence boundary: a board payload decodes straight through, an absent or
/// corrupt config falls back to the default board (never crashes), unknown keys are
/// ignored and never re-persisted, and encoding always writes the board shape. The
/// board-config internals themselves are exercised in the Core package's
/// `MonitorBoardConfigurationTests`; this suite pins the decode boundary the
/// integration owns.
@Suite("Monitor board config decode (WallpaperContent boundary)")
struct MonitorBoardConfigDecodeTests {

    private func decodeContent(_ json: String) throws -> WallpaperContent {
        try JSONDecoder().decode(WallpaperContent.self, from: Data(json.utf8))
    }

    private func encodeString(_ content: WallpaperContent) throws -> String {
        String(data: try JSONEncoder().encode(content), encoding: .utf8) ?? ""
    }

    // MARK: - Board shape decode

    @Test("A board payload decodes its widgets, sizes and board-level fields")
    func boardPayloadDecodes() throws {
        let json = """
        {"monitor":{"config":{"schemaVersion":2,"gridColumns":12,"refreshHz":0.75,"mouseInteractionEnabled":true,"widgets":[{"kind":"gpu","size":"m","x":0.0,"y":0.0},{"kind":"disk","size":"s","x":0.5,"y":0.5}]}}}
        """
        guard case .monitor(let board) = try decodeContent(json) else {
            Issue.record("Expected .monitor content")
            return
        }
        #expect(board.widgets.map(\.kind) == [.gpu, .disk])
        #expect(board.widgets.map(\.size) == [.medium, .small])
        #expect(board.refreshHz == 0.75)
        #expect(board.mouseInteractionEnabled == true)
    }

    @Test("A widgets-only config keeps exactly the placements it lists")
    func widgetsOnlyConfigKeepsPlacements() throws {
        let json = """
        {"monitor":{"config":{"widgets":[{"kind":"clock","size":"s","x":0.1,"y":0.1}]}}}
        """
        guard case .monitor(let board) = try decodeContent(json) else {
            Issue.record("Expected .monitor content")
            return
        }
        #expect(board.widgets.map(\.kind) == [.clock])
    }

    // MARK: - Graceful fallback

    @Test("An absent monitor config decodes to the default board")
    func absentConfigIsDefaultBoard() throws {
        guard case .monitor(let board) = try decodeContent(#"{"monitor":{}}"#) else {
            Issue.record("Expected .monitor content")
            return
        }
        #expect(board == MonitorBoardConfiguration.default)
    }

    @Test("A corrupt config decodes to the default board, never a half-decoded one")
    func corruptConfigFallsToDefaultBoard() throws {
        // `widgets` is present but is a string, so the board decode throws. The
        // boundary treats the slot as absent (nil) and substitutes the default
        // board rather than a partially-decoded one.
        let json = """
        {"monitor":{"config":{"schemaVersion":2,"widgets":"corrupt-not-an-array"}}}
        """
        guard case .monitor(let board) = try decodeContent(json) else {
            Issue.record("Expected .monitor content")
            return
        }
        #expect(board == MonitorBoardConfiguration.default)
    }

    // MARK: - Unknown keys ignored + encode always writes the board shape

    @Test("Unknown config keys are ignored on decode and never re-persisted")
    func unknownKeysIgnoredAndNotPersisted() throws {
        // A blob carrying keys the board doesn't know (e.g. a pre-board build's
        // module toggles) decodes to the default system board — the strays are
        // dropped, no widgets key present — and re-encoding writes only the board
        // shape. (It is an equivalent default board, not the `.default` singleton:
        // absent widgets are re-seeded with fresh placement ids, so compare kinds.)
        let json = """
        {"monitor":{"config":{"systemEnabled":true,"agentsEnabled":false,"showTopProcesses":true}}}
        """
        guard case .monitor(let board) = try decodeContent(json) else {
            Issue.record("Expected .monitor content")
            return
        }
        #expect(board.widgets.map(\.kind) == MonitorBoardConfiguration.default.widgets.map(\.kind))
        #expect(board.gridColumns == 10)
        #expect(board.refreshHz == 1.0)
        #expect(board.mouseInteractionEnabled == false)

        let reEncoded = try encodeString(.monitor(board))
        #expect(reEncoded.contains("\"widgets\""))
        #expect(reEncoded.contains("\"schemaVersion\""))
        #expect(!reEncoded.contains("systemEnabled"))
        #expect(!reEncoded.contains("agentsEnabled"))
        #expect(!reEncoded.contains("showTopProcesses"))
    }

    @Test("A board config round-trips unchanged through WallpaperContent")
    func boardRoundTrip() throws {
        var board = MonitorBoardConfiguration()
        board.gridColumns = 12
        board.refreshHz = 1.0
        board.mouseInteractionEnabled = true
        board.widgets = [
            MonitorWidgetPlacement(kind: .cpu, size: .medium, x: 0.0, y: 0.0),
            MonitorWidgetPlacement(kind: .fleet, size: .medium, x: 0.4, y: 0.2),
        ]
        let content = WallpaperContent.monitor(board)

        let decoded = try decodeContent(try encodeString(content))
        #expect(decoded == content)
    }

    // MARK: - savedMonitorConfiguration slot

    @Test("A board payload in the savedMonitorConfiguration slot decodes on ScreenConfiguration")
    func savedSlotDecodes() throws {
        let json = """
        {
          "screenID": 7,
          "activeWallpaper": {"monitor":{"config":{"widgets":[{"kind":"clock","size":"s","x":0.0,"y":0.0}]}}},
          "savedMonitorConfiguration": {"schemaVersion":2,"widgets":[{"kind":"gpu","size":"m","x":0.0,"y":0.0}]}
        }
        """
        let config = try JSONDecoder().decode(ScreenConfiguration.self, from: Data(json.utf8))
        let saved = try #require(config.savedMonitorConfiguration)
        #expect(saved.widgets.map(\.kind) == [.gpu])
    }
}
