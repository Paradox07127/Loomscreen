import Foundation
import Testing
@testable import LiveWallpaper

@Suite("ScreenDetailDraftState")
struct ScreenDetailDraftStateTests {
    @Test("Default matches no-config branch defaults")
    func defaultMatchesNoConfigBranchDefaults() {
        let expected = ScreenDetailDraftState(
            playbackSpeed: 1.0,
            selectedFitMode: .aspectFill,
            selectedVideoDisplayMode: .perDisplay,
            selectedWallpaperType: .video,
            selectedWallpaperMode: .playlist,
            selectedParticleEffect: .none,
            effectConfig: .default,
            selectedShaderSource: .builtin(.waves),
            htmlSource: nil,
            htmlConfig: .default,
            setAsLockScreen: false,
            playlistBookmarks: [],
            shufflePlaylist: false,
            playlistRotationMinutes: nil,
            scheduleSlots: [],
            videoMuted: true,
            videoVolume: 1.0,
            videoColorSpace: .auto,
            particleDensity: 1.0,
            selectedFrameRateLimit: .fps60,
            hasPreviewSource: false
        )

        #expect(ScreenDetailDraftState.default == expected)
    }

    @Test("Nil config equals default modulo preview-source fallback")
    func nilConfigEqualsDefaultModuloPreviewSourceFallback() {
        #expect(
            ScreenDetailDraftState.from(
                config: nil,
                fallbackHasPreviewSource: false
            ) == .default
        )

        var expected = ScreenDetailDraftState.default
        expected.hasPreviewSource = true

        #expect(
            ScreenDetailDraftState.from(
                config: nil,
                fallbackHasPreviewSource: true
            ) == expected
        )
    }

    @Test("Video config maps every draft field")
    func videoConfigMapsEveryField() {
        var effectConfig = VideoEffectConfig.default
        effectConfig.blurRadius = 2
        effectConfig.saturation = 0.8
        effectConfig.weatherReactive = true
        effectConfig.particleDensity = 2.25

        let playlistBookmarks = [
            Data([0x02]),
            Data([0x03]),
        ]
        let scheduleSlots = [
            ScheduleSlot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                startHour: 8,
                endHour: 17,
                videoBookmarkData: Data([0x04]),
                label: "Work"
            ),
        ]

        var config = ScreenConfiguration(
            screenID: 42,
            wallpaper: .video(bookmarkData: Data([0x01])),
            playbackSpeed: 1.5,
            fitMode: .aspectFit,
            videoDisplayMode: .spanAllDisplays,
            frameRateLimit: .fps30,
            particleEffect: .rain,
            effectConfig: effectConfig,
            scheduleSlots: scheduleSlots,
            playlistBookmarks: playlistBookmarks,
            shufflePlaylist: true,
            playlistRotationMinutes: 15,
            setAsLockScreen: true
        )
        config.wallpaperMode = .schedule
        config.muted = false
        config.videoVolume = 0.4
        config.videoColorSpace = .displayP3

        let draft = ScreenDetailDraftState.from(
            config: config,
            fallbackHasPreviewSource: false
        )

        #expect(draft.playbackSpeed == 1.5)
        #expect(draft.selectedFitMode == .aspectFit)
        #expect(draft.selectedVideoDisplayMode == .spanAllDisplays)
        #expect(draft.selectedWallpaperType == .video)
        #expect(draft.selectedWallpaperMode == .schedule)
        #expect(draft.selectedParticleEffect == .rain)
        #expect(draft.effectConfig == effectConfig)
        #expect(draft.selectedShaderSource == .builtin(.waves))
        #expect(draft.htmlSource == nil)
        #expect(draft.htmlConfig == .default)
        #expect(draft.setAsLockScreen == true)
        #expect(draft.playlistBookmarks == playlistBookmarks)
        #expect(draft.shufflePlaylist == true)
        #expect(draft.playlistRotationMinutes == 15)
        #expect(draft.scheduleSlots == scheduleSlots)
        #expect(draft.videoMuted == false)
        #expect(draft.videoVolume == 0.4)
        #expect(draft.videoColorSpace == .displayP3)
        #expect(draft.particleDensity == 2.25)
        #expect(draft.selectedFrameRateLimit == .fps30)
        #expect(draft.hasPreviewSource == true)
    }

    @Test("HTML config maps source, config, and wallpaper type")
    func htmlConfigMapsSourceConfigAndWallpaperType() {
        let source = HTMLSource.url(URL(string: "https://example.com/wallpaper")!)
        let htmlConfig = HTMLConfig(
            allowJavaScript: false,
            allowMouseInteraction: true,
            blockTrackers: false,
            customCSS: "body { opacity: 0.5; }"
        )
        let config = ScreenConfiguration(
            screenID: 43,
            wallpaper: .html(source: source, config: htmlConfig)
        )

        let draft = ScreenDetailDraftState.from(
            config: config,
            fallbackHasPreviewSource: true
        )

        #expect(draft.htmlSource == source)
        #expect(draft.htmlConfig == htmlConfig)
        #expect(draft.selectedWallpaperType == .html)
        #expect(draft.hasPreviewSource == false)
    }

    @Test("Shader config maps selected preset and wallpaper type")
    func shaderConfigMapsPresetAndWallpaperType() {
        let config = ScreenConfiguration(
            screenID: 44,
            wallpaper: .metalShader(.aurora)
        )

        let draft = ScreenDetailDraftState.from(
            config: config,
            fallbackHasPreviewSource: true
        )

        #expect(draft.selectedShaderSource == .builtin(.aurora))
        #expect(draft.selectedWallpaperType == .metalShader)
        #expect(draft.hasPreviewSource == false)
    }

    @Test("Nil config resets stale shader preset and color space (C3 regression)")
    func nilConfigDropsShaderPresetAndColorSpaceResidue() {
        var config = ScreenConfiguration(
            screenID: 45,
            wallpaper: .metalShader(.plasma)
        )
        config.videoColorSpace = .rec2020HDR

        var draft = ScreenDetailDraftState.from(
            config: config,
            fallbackHasPreviewSource: false
        )
        #expect(draft.selectedShaderSource == .builtin(.plasma))
        #expect(draft.videoColorSpace == .rec2020HDR)

        draft = .from(
            config: nil,
            fallbackHasPreviewSource: false
        )

        #expect(draft.selectedShaderSource == .builtin(.waves))
        #expect(draft.videoColorSpace == .auto)
        #expect(draft.hasPreviewSource == false)
    }
}
