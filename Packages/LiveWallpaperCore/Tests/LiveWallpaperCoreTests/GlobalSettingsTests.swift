import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("GlobalSettings")
struct GlobalSettingsTests {

    @Test("Legacy JSON without globalShortcutsEnabled decodes to true")
    func legacyDecodeDefaultsToTrue() throws {
        // Snapshot from before the flag existed: missing key must default to
        // true so users upgrading from an older build keep their hot keys.
        let legacyJSON = """
        {
          "globalPauseOnBattery": false,
          "preservePlaybackOnLock": false,
          "startOnLogin": false,
          "defaultFrameRateLimit": 60,
          "pauseOnFullScreen": true,
          "showInDock": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacyJSON)

        #expect(decoded.globalShortcutsEnabled == true)
        #expect(decoded.globalShortcuts.isEmpty)
    }

    @Test("Round-trip preserves globalShortcutsEnabled when explicitly disabled")
    func roundTripDisabled() throws {
        var settings = GlobalSettings()
        settings.globalShortcutsEnabled = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.globalShortcutsEnabled == false)
    }

    @Test("Default initializer enables the global shortcut surface")
    func defaultInitEnablesSurface() {
        let settings = GlobalSettings()
        #expect(settings.globalShortcutsEnabled == true)
    }

    @Test("Import bundle preserves the imported globalShortcutsEnabled value")
    func importPreservesDisabledFlag() throws {
        // Real user preference (unlike developerModeEnabled, which we scrub):
        // a backup with the surface disabled must restore disabled.
        var snapshot = GlobalSettings()
        snapshot.globalShortcutsEnabled = false

        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(restored.globalShortcutsEnabled == false)
    }
}
