import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("Monitor board config decode (WallpaperContent boundary)")
struct MonitorBoardConfigDecodeTests {

    private func decodeContent(_ json: String) throws -> WallpaperContent {
        try JSONDecoder().decode(WallpaperContent.self, from: Data(json.utf8))
    }

    private func encodeString(_ content: WallpaperContent) throws -> String {
        String(data: try JSONEncoder().encode(content), encoding: .utf8) ?? ""
    }

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
        {"monitor":{"config":{"widgets":[{"kind":"network","size":"s","x":0.1,"y":0.1}]}}}
        """
        guard case .monitor(let board) = try decodeContent(json) else {
            Issue.record("Expected .monitor content")
            return
        }
        #expect(board.widgets.map(\.kind) == [.network])
    }

    @Test("A retired kind (clock/health) is dropped on decode, keeping the rest")
    func retiredKindsAreDropped() throws {
        let json = """
        {"monitor":{"config":{"widgets":[{"kind":"clock","size":"s","x":0.1,"y":0.1},{"kind":"health","size":"s","x":0.3,"y":0.1},{"kind":"cpu","size":"m","x":0.5,"y":0.1}]}}}
        """
        guard case .monitor(let board) = try decodeContent(json) else {
            Issue.record("Expected .monitor content")
            return
        }
        #expect(board.widgets.map(\.kind) == [.cpu])
    }

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
        let json = """
        {"monitor":{"config":{"schemaVersion":2,"widgets":"corrupt-not-an-array"}}}
        """
        guard case .monitor(let board) = try decodeContent(json) else {
            Issue.record("Expected .monitor content")
            return
        }
        #expect(board == MonitorBoardConfiguration.default)
    }

    @Test("Unknown config keys are ignored on decode and never re-persisted")
    func unknownKeysIgnoredAndNotPersisted() throws {
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
