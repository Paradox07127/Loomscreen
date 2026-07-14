import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("Monitor overlay configuration")
struct MonitorOverlayConfigurationTests {

    @Test("Default overlay is off, desktop layer, default board")
    func defaults() {
        let d = MonitorOverlayConfiguration.default
        #expect(d.enabled == false)
        #expect(d.level == .desktop)
        #expect(d.board == MonitorBoardConfiguration.default)
    }

    @Test("An empty object decodes to the defaults")
    func emptyObjectDecodesDefault() throws {
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: Data("{}".utf8))
        #expect(decoded == .default)
    }

    @Test("Round-trip preserves enabled / level / board")
    func roundTrip() throws {
        var overlay = MonitorOverlayConfiguration(enabled: true, level: .front)
        overlay.board.widgets = [MonitorWidgetPlacement(kind: .gpu, size: .medium, x: 0.1, y: 0.2)]
        overlay.board.mouseInteractionEnabled = true

        let data = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: data)
        #expect(decoded == overlay)
        #expect(decoded.level == .front)
        #expect(decoded.board.widgets.map(\.kind) == [.gpu])
    }

    @Test("An unknown level string falls back to the desktop default")
    func unknownLevelFallsBack() throws {
        let json = #"{ "enabled": true, "level": "middle" }"#
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: Data(json.utf8))
        #expect(decoded.enabled == true)
        #expect(decoded.level == .desktop)
    }

    // MARK: - decodeIfPresent boundary

    private struct Probe: Decodable {
        let decoded: MonitorOverlayConfiguration?
        enum Key: String, CodingKey { case overlay }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            decoded = MonitorOverlayConfiguration.decodeIfPresent(from: c, forKey: .overlay)
        }
    }

    private func decodeOverlay(_ json: String) throws -> MonitorOverlayConfiguration? {
        try JSONDecoder().decode(Probe.self, from: Data("{ \"overlay\": \(json) }".utf8)).decoded
    }

    @Test("Absent overlay slot decodes to nil")
    func absentSlotIsNil() throws {
        let decoded = try JSONDecoder().decode(Probe.self, from: Data("{}".utf8)).decoded
        #expect(decoded == nil)
    }

    @Test("A present overlay slot decodes its value")
    func presentSlotDecodes() throws {
        let decoded = try decodeOverlay(#"{ "enabled": true, "level": "front" }"#)
        #expect(decoded?.enabled == true)
        #expect(decoded?.level == .front)
    }

    @Test("A corrupt overlay slot decodes to nil, never a half-value")
    func corruptSlotIsNil() throws {
        let decoded = try decodeOverlay(#"{ "board": "not-an-object" }"#)
        #expect(decoded == nil)
    }

    // MARK: - ScreenConfiguration carries the overlay

    @Test("ScreenConfiguration round-trips its monitorOverlay slot")
    func screenConfigurationRoundTripsOverlay() throws {
        var config = ScreenConfiguration(screenID: 3, wallpaper: .metalShader(.builtin(.waves)))
        config.monitorOverlay = MonitorOverlayConfiguration(enabled: true, level: .front)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)
        #expect(decoded.monitorOverlay?.enabled == true)
        #expect(decoded.monitorOverlay?.level == .front)
    }

    @Test("A ScreenConfiguration with no overlay decodes it as nil")
    func screenConfigurationWithoutOverlayIsNil() throws {
        let config = ScreenConfiguration(screenID: 4, wallpaper: .metalShader(.builtin(.waves)))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)
        #expect(decoded.monitorOverlay == nil)
    }
}
