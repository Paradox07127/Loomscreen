import Foundation
import Testing
@testable import LiveWallpaper

/// Phase 1.x §A16 lock: Day 1 added `wpeOrigin` and `recentWPEImports` to
/// existing persisted blobs. Both must round-trip cleanly AND survive when
/// the blob is missing or malformed (lossy decode).
@Suite("ScreenConfiguration / GlobalSettings persistence compatibility")
struct ScreenConfigurationCompatTests {

    // MARK: - ScreenConfiguration: legacy plist (no wpeOrigin field)

    @Test("Decoding a legacy ScreenConfiguration without wpeOrigin yields nil and preserves other fields")
    func decodeLegacyConfigurationWithoutWPEOrigin() throws {
        let baselineConfig = ScreenConfiguration(
            screenID: 12_345,
            wallpaper: .video(bookmarkData: Data([0xAA, 0xBB])),
            playbackSpeed: 1.5,
            fitMode: .aspectFit,
            frameRateLimit: .fps30,
            savedVideoBookmarkData: Data([0xAA, 0xBB])
        )
        let baseline = try JSONEncoder().encode(baselineConfig)
        var dict = try #require(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        dict.removeValue(forKey: "wpeOrigin")
        let stripped = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)

        let config = try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)

        #expect(config.screenID == 12_345)
        #expect(config.wpeOrigin == nil)
        #expect(config.playbackSpeed == 1.5)
        #expect(config.fitMode == .aspectFit)
    }

    @Test("sceneMouseInteractionEnabled round-trips and defaults to true on legacy blobs")
    func sceneMouseInteractionRoundTripAndLegacyDefault() throws {
        var config = ScreenConfiguration(
            screenID: 12_345,
            wallpaper: .video(bookmarkData: Data([0xAA, 0xBB])),
            savedVideoBookmarkData: Data([0xAA, 0xBB])
        )
        config.sceneMouseInteractionEnabled = false

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: encoded)
        #expect(decoded.sceneMouseInteractionEnabled == false)

        var dict = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        dict.removeValue(forKey: "sceneMouseInteractionEnabled")
        let stripped = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        let legacy = try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)
        #expect(legacy.sceneMouseInteractionEnabled == true)
    }

    @Test("sceneClickCaptureEnabled round-trips and defaults to false on legacy blobs")
    func sceneClickCaptureRoundTripAndLegacyDefault() throws {
        var config = ScreenConfiguration(
            screenID: 12_345,
            wallpaper: .video(bookmarkData: Data([0xAA, 0xBB])),
            savedVideoBookmarkData: Data([0xAA, 0xBB])
        )
        config.sceneClickCaptureEnabled = true

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: encoded)
        #expect(decoded.sceneClickCaptureEnabled == true)

        var dict = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        dict.removeValue(forKey: "sceneClickCaptureEnabled")
        let stripped = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        let legacy = try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)
        #expect(legacy.sceneClickCaptureEnabled == false)
    }

    @Test("Decoding a legacy ScreenConfiguration without videoVolume defaults to full volume")
    func decodeLegacyConfigurationWithoutVideoVolume() throws {
        let baselineConfig = ScreenConfiguration(
            screenID: 12_345,
            wallpaper: .video(bookmarkData: Data([0xAA, 0xBB])),
            savedVideoBookmarkData: Data([0xAA, 0xBB])
        )
        let baseline = try JSONEncoder().encode(baselineConfig)
        var dict = try #require(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        dict.removeValue(forKey: "videoVolume")
        let stripped = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)

        let config = try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)

        #expect(config.videoVolume == 1.0)
    }

    @Test("Decoding a legacy ScreenConfiguration without videoDisplayMode defaults to per-display")
    func decodeLegacyConfigurationWithoutVideoDisplayMode() throws {
        let baselineConfig = ScreenConfiguration(
            screenID: 12_345,
            wallpaper: .video(bookmarkData: Data([0xAA, 0xBB])),
            savedVideoBookmarkData: Data([0xAA, 0xBB])
        )
        let baseline = try JSONEncoder().encode(baselineConfig)
        var dict = try #require(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        dict.removeValue(forKey: "videoDisplayMode")
        let stripped = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)

        let config = try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)

        #expect(config.videoDisplayMode == .perDisplay)
    }

    @Test("Round-tripping a configuration with wpeOrigin preserves every field")
    func roundTripsWPEOriginThroughCodable() throws {
        let origin = WPEOrigin(
            workshopID: "round-trip",
            title: "Round Trip Wallpaper",
            originalType: .video,
            sourceFolderBookmark: Data([0x01, 0x02, 0x03]),
            cacheRelativePath: "wpe-cache/round-trip",
            previewFileName: "preview.gif"
        )

        var config = ScreenConfiguration(
            screenID: 999,
            wallpaper: .video(bookmarkData: Data([0xFF])),
            savedVideoBookmarkData: Data([0xFF])
        )
        config.wpeOrigin = origin

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.wpeOrigin == origin)
        #expect(decoded.screenID == 999)
    }

    @Test("Malformed wpeOrigin blob falls back to nil without invalidating the rest")
    func lossilyDecodesMalformedWPEOrigin() throws {
        let origin = WPEOrigin(
            workshopID: "x",
            title: "Lossy",
            originalType: .scene,
            sourceFolderBookmark: Data([0x00]),
            cacheRelativePath: nil,
            previewFileName: nil
        )
        var config = ScreenConfiguration(
            screenID: 1,
            wallpaper: .video(bookmarkData: Data([0x01]))
        )
        config.wpeOrigin = origin

        let baseline = try JSONEncoder().encode(config)
        var dict = try #require(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        dict["wpeOrigin"] = ["totally": "wrong"]
        let mutated = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)

        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: mutated)

        #expect(decoded.wpeOrigin == nil, "Malformed WPE blob must not invalidate the whole configuration")
        #expect(decoded.screenID == 1)
    }

    // MARK: - GlobalSettings: legacy plist (no recentWPEImports field)

    @Test("Decoding legacy GlobalSettings without recentWPEImports yields empty array")
    func decodeLegacyGlobalSettingsWithoutRecentImports() throws {
        let baseline = try JSONEncoder().encode(GlobalSettings(globalPauseOnBattery: true, pauseOnFullScreen: true))
        var dict = try #require(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        dict.removeValue(forKey: "recentWPEImports")
        let stripped = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)

        let settings = try JSONDecoder().decode(GlobalSettings.self, from: stripped)

        #expect(settings.recentWPEImports.isEmpty)
        #expect(settings.globalPauseOnBattery == true)
    }

    @Test("Malformed recentWPEImports falls back to empty array without losing other settings")
    func lossilyDecodesMalformedRecentImports() throws {
        let baseline = try JSONEncoder().encode(GlobalSettings(pauseOnFullScreen: true))
        var dict = try #require(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        dict["recentWPEImports"] = ["malformed-not-an-array-of-entries"]
        let mutated = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)

        let settings = try JSONDecoder().decode(GlobalSettings.self, from: mutated)

        #expect(settings.recentWPEImports.isEmpty)
        #expect(settings.pauseOnFullScreen == true)
    }

    // Type-aware default: a brand-new ScreenConfiguration picks the
    // per-type natural frame rate so the picker (which reads this
    // value) and the runtime (which the picker drives) start out
    // agreeing. Pre-fix the picker said "60 FPS" while WPE scenes
    // wanted 30 — the contradiction that prompted this change.
    @Test("New scene ScreenConfiguration defaults to fps30 (WPE parity)")
    func newSceneConfigurationDefaultsToThirty() throws {
        let descriptor = SceneDescriptor(
            workshopID: "test-fps-default",
            cacheRelativePath: "test-fps-default",
            entryFile: "scene.json",
            capabilityTier: .degraded
        )
        let config = ScreenConfiguration(screenID: 1, wallpaper: .scene(descriptor))
        #expect(config.frameRateLimit == .fps30)
    }

    @Test("New video ScreenConfiguration keeps fps60 (native pass-through)")
    func newVideoConfigurationDefaultsToSixty() {
        let config = ScreenConfiguration(screenID: 1, wallpaper: .video(bookmarkData: Data([0x01])))
        #expect(config.frameRateLimit == .fps60)
    }

    @Test("Explicit frameRateLimit overrides the type-aware default")
    func explicitFrameRateLimitOverridesDefault() throws {
        let descriptor = SceneDescriptor(
            workshopID: "test-fps-override",
            cacheRelativePath: "test-fps-override",
            entryFile: "scene.json",
            capabilityTier: .degraded
        )
        let config = ScreenConfiguration(
            screenID: 1,
            wallpaper: .scene(descriptor),
            frameRateLimit: .fps60
        )
        #expect(config.frameRateLimit == .fps60)
    }
}
