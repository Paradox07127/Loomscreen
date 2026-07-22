import Foundation
import LiveWallpaperCore
import Testing

@Suite("HTMLConfig persistence")
struct HTMLConfigPersistenceTests {

    @Test("New suspension knobs round-trip through encode/decode")
    func newFieldsRoundTrip() throws {
        var cfg = HTMLConfig()
        cfg.cspEnforcementEnabled = true
        cfg.aggressiveSuspend = true

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(HTMLConfig.self, from: data)

        #expect(decoded.cspEnforcementEnabled == true)
        #expect(decoded.aggressiveSuspend == true)
    }

    @Test("Legacy config without cspEnforcementEnabled / aggressiveSuspend defaults to off")
    func legacyConfigDefaultsOff() throws {
        let legacy = #"""
        {
            "allowJavaScript": true,
            "allowMouseInteraction": false,
            "blockTrackers": true,
            "muteAudio": false,
            "audioVolume": 1,
            "refreshIntervalSeconds": 0,
            "transformScale": 1,
            "transformTranslateX": 0,
            "transformTranslateY": 0,
            "transformRotationDegrees": 0,
            "physicalPixelLayout": false,
            "useEphemeralStorage": false,
            "maxRetries": 3
        }
        """#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HTMLConfig.self, from: legacy)
        #expect(decoded.cspEnforcementEnabled == false)
        #expect(decoded.aggressiveSuspend == false)
        #expect(decoded.allowJavaScript == true)
        #expect(decoded.blockTrackers == true)
        #expect(decoded.maxRetries == 3)
    }

    @Test("Legacy config without useEphemeralStorage defaults clear data on exit on")
    func legacyConfigDefaultsClearDataOnExitOn() throws {
        let legacy = #"""
        {
            "allowJavaScript": true,
            "allowMouseInteraction": false,
            "blockTrackers": true,
            "muteAudio": false,
            "audioVolume": 1,
            "refreshIntervalSeconds": 0,
            "transformScale": 1,
            "transformTranslateX": 0,
            "transformTranslateY": 0,
            "transformRotationDegrees": 0,
            "physicalPixelLayout": false,
            "maxRetries": 3
        }
        """#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HTMLConfig.self, from: legacy)
        #expect(decoded.useEphemeralStorage == true)
    }

    @Test("Default HTMLConfig leaves both suspension knobs off")
    func defaultConfigDisablesNewKnobs() {
        let cfg = HTMLConfig.default
        #expect(cfg.cspEnforcementEnabled == false)
        #expect(cfg.aggressiveSuspend == false)
        #expect(cfg.useEphemeralStorage == true)
    }
}
