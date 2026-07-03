import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("DisplayDefaults")
struct DisplayDefaultsTests {
    @Test("Default playback baselines follow wallpaper type natural frame rates")
    func defaultBaselinesFollowWallpaperType() {
        let defaults = DisplayDefaults()

        #expect(defaults.playbackDefaults(for: .video).frameRateLimit == .fps60)
        #expect(defaults.playbackDefaults(for: .html).frameRateLimit == .fps60)
        #expect(defaults.playbackDefaults(for: .metalShader).frameRateLimit == .fps60)
        #expect(defaults.playbackDefaults(for: .scene).frameRateLimit == .fps30)
        #expect(defaults.playbackDefaults(for: .scene).sceneMouseInteractionEnabled == true)
        #expect(defaults.playbackDefaults(for: .scene).sceneClickCaptureEnabled == false)
    }

    @Test("Screen configuration reports no playback difference when matching defaults")
    func matchingConfigurationDoesNotDiffer() {
        let defaults = DisplayDefaults()
        let configuration = ScreenConfiguration(
            screenID: 7,
            wallpaper: .metalShader(.builtin(.waves))
        )

        #expect(configuration.playbackDiffers(from: defaults) == false)
    }

    @Test("Reset playback applies only playback defaults and preserves content")
    func resetPlaybackPreservesContent() {
        var defaults = DisplayDefaults()
        defaults.scene.muted = false
        defaults.scene.videoVolume = 0.35
        defaults.scene.frameRateLimit = .fps15
        defaults.scene.fitMode = .aspectFit
        defaults.scene.sceneMouseInteractionEnabled = false
        defaults.scene.sceneClickCaptureEnabled = true

        let descriptor = SceneDescriptor(
            workshopID: "123",
            cacheRelativePath: "wpe-cache/123",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        var configuration = ScreenConfiguration(
            screenID: 9,
            wallpaper: .scene(descriptor),
            frameRateLimit: .fps60,
            particleEffect: .rain,
            scheduleSlots: [
                ScheduleSlot(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                    startHour: 8,
                    endHour: 17,
                    videoBookmarkData: Data([0x01]),
                    label: "Work"
                )
            ],
            playlistBookmarks: [Data([0x02])],
            shufflePlaylist: true,
            playlistRotationMinutes: 20,
            setAsLockScreen: true
        )
        configuration.muted = true
        configuration.videoVolume = 1.0
        configuration.sceneMouseInteractionEnabled = true
        configuration.sceneClickCaptureEnabled = false

        configuration.resetPlayback(to: defaults)

        #expect(configuration.activeWallpaper == .scene(descriptor))
        #expect(configuration.frameRateLimit == .fps15)
        #expect(configuration.fitMode == .aspectFit)
        #expect(configuration.muted == false)
        #expect(configuration.videoVolume == 0.35)
        #expect(configuration.sceneMouseInteractionEnabled == false)
        #expect(configuration.sceneClickCaptureEnabled == true)
        #expect(configuration.particleEffect == .rain)
        #expect(configuration.scheduleSlots?.count == 1)
        #expect(configuration.playlistBookmarks == [Data([0x02])])
        #expect(configuration.shufflePlaylist == true)
        #expect(configuration.playlistRotationMinutes == 20)
        #expect(configuration.setAsLockScreen == true)
    }

    @Test("HTML playback reset updates HTML audio and interaction without replacing source")
    func htmlPlaybackResetUpdatesHTMLPlaybackDefaults() {
        var defaults = DisplayDefaults()
        defaults.html.muted = true
        defaults.html.videoVolume = 0.2
        defaults.html.interactiveInputEnabled = false

        let source = HTMLSource.inline("<html></html>")
        let config = HTMLConfig(allowMouseInteraction: true, muteAudio: false, audioVolume: 1.0)
        var configuration = ScreenConfiguration(
            screenID: 11,
            wallpaper: .html(source: source, config: config)
        )

        configuration.resetPlayback(to: defaults)

        guard case .html(let nextSource, let nextConfig) = configuration.activeWallpaper else {
            Issue.record("Expected HTML wallpaper after reset")
            return
        }
        #expect(nextSource == source)
        #expect(nextConfig.muteAudio == true)
        #expect(nextConfig.audioVolume == 0.2)
        #expect(nextConfig.allowMouseInteraction == false)
    }

    @Test("Saved HTML config participates in stored playback difference detection")
    func savedHTMLConfigParticipatesInStoredPlaybackDiff() {
        var defaults = DisplayDefaults()
        defaults.video.muted = true
        defaults.video.videoVolume = 1.0
        defaults.html.muted = true
        defaults.html.videoVolume = 0.25
        defaults.html.interactiveInputEnabled = false

        var configuration = ScreenConfiguration(
            screenID: 12,
            wallpaper: .video(bookmarkData: Data([0x01]))
        )
        configuration.savedHTMLConfig = HTMLConfig(
            allowMouseInteraction: true,
            muteAudio: false,
            audioVolume: 1.0
        )

        #expect(!configuration.playbackDiffers(from: defaults))
        #expect(configuration.storedPlaybackDiffers(from: defaults))

        configuration.resetStoredPlayback(to: defaults)

        #expect(configuration.savedHTMLConfig?.muteAudio == true)
        #expect(configuration.savedHTMLConfig?.audioVolume == 0.25)
        #expect(configuration.savedHTMLConfig?.allowMouseInteraction == false)
        #expect(!configuration.storedPlaybackDiffers(from: defaults))
    }

    @Test("Interaction defaults decode legacy scene click capture key")
    func interactionDefaultsDecodeLegacyClickCaptureKey() throws {
        let data = #"{"sceneClickCaptureEnabled":true}"#.data(using: .utf8)!

        let defaults = try JSONDecoder().decode(DisplayPlaybackDefaults.self, from: data)

        #expect(defaults.interactiveInputEnabled == true)
        #expect(defaults.sceneClickCaptureEnabled == true)

        let encoded = try JSONEncoder().encode(defaults)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?["interactiveInputEnabled"] as? Bool == true)
        #expect(object?["sceneClickCaptureEnabled"] == nil)
    }
}
