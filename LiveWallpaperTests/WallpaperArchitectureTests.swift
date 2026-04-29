import AppKit
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WallpaperSessionDefinition")
struct WallpaperSessionDefinitionTests {

    @Test("Remote HTML configuration resolves into a typed session definition")
    func remoteHTMLConfigurationResolves() {
        let url = URL(string: "https://example.com/wallpaper")!
        let configuration = ScreenConfiguration(
            screenID: 11,
            wallpaper: .html(source: .url(url), config: .default)
        )

        let definition = WallpaperSessionDefinition(configuration: configuration)

        #expect(definition == .html(.url(url), .default))
    }

    @Test("Inline HTML configuration resolves into a typed session definition")
    func inlineHTMLConfigurationResolves() {
        let html = "<html><body>Inline</body></html>"
        let configuration = ScreenConfiguration(
            screenID: 13,
            wallpaper: .html(source: .inline(html), config: .default)
        )

        let definition = WallpaperSessionDefinition(configuration: configuration)

        #expect(definition == .html(.inline(html), .default))
    }

    @Test("Empty inline HTML configuration produces no session")
    func emptyInlineHTMLProducesNoSession() {
        let configuration = ScreenConfiguration(
            screenID: 14,
            wallpaper: .html(source: .inline(""), config: .default)
        )

        #expect(WallpaperSessionDefinition(configuration: configuration) == nil)
    }

    @Test("Session definition display names come from typed content")
    func sessionDefinitionDisplayNameUsesTypedContent() {
        let definitions: [WallpaperSessionDefinition] = [
            .html(.url(URL(string: "https://example.com/live")!), .default),
            .html(.inline("<html></html>"), .default),
            .metalShader(.aurora),
            .video(bookmarkData: Data([0x01, 0x02])),
        ]

        let displayNames = definitions.map { definition in
            definition.displayName(using: { _ in "Demo.mov" })
        }

        #expect(displayNames[0] == "example.com")
        #expect(displayNames[1] == "Inline HTML")
        #expect(displayNames[2] == "Aurora")
        #expect(displayNames[3] == "Demo.mov")
    }
}

@Suite("WallpaperStatusAggregator")
struct WallpaperStatusAggregatorTests {

    @Test("HTML wallpaper counts as configured and active")
    func htmlWallpaperCountsAsActive() {
        let summaries = [
            WallpaperSessionSummary(
                wallpaperType: .html,
                activity: .active,
                supportsPlaybackControl: false,
                subtitle: "https://example.com"
            )
        ]

        let overview = WallpaperStatusAggregator.overview(for: summaries)

        #expect(overview == .active)
    }

    @Test("Paused video with no active sessions reports paused")
    func pausedVideoReportsPaused() {
        let summaries = [
            WallpaperSessionSummary(
                wallpaperType: .video,
                activity: .paused,
                supportsPlaybackControl: true,
                subtitle: "Demo.mp4"
            )
        ]

        let overview = WallpaperStatusAggregator.overview(for: summaries)

        #expect(overview == .paused)
    }

    @Test("No configured sessions reports not configured")
    func noConfiguredSessionsReportsNotConfigured() {
        let summaries = [WallpaperSessionSummary.notConfigured]

        let overview = WallpaperStatusAggregator.overview(for: summaries)

        #expect(overview == .notConfigured)
    }
}

@Suite("WallpaperSessionSummaryCache")
struct WallpaperSessionSummaryCacheTests {
    @Test("Cached summary wins over fallback")
    func cachedSummaryWinsOverFallback() {
        let active = WallpaperSessionSummary(
            wallpaperType: .video,
            activity: .active,
            supportsPlaybackControl: true,
            subtitle: nil
        )
        var cache = WallpaperSessionSummaryCache()

        cache.replace(with: [(42, active)])

        #expect(cache.summary(for: 42, fallback: .notConfigured) == active)
    }

    @Test("Replacing cache removes stale screen IDs")
    func replacingCacheRemovesStaleScreenIDs() {
        let paused = WallpaperSessionSummary(
            wallpaperType: .video,
            activity: .paused,
            supportsPlaybackControl: true,
            subtitle: nil
        )
        var cache = WallpaperSessionSummaryCache()

        cache.replace(with: [(1, paused)])
        cache.replace(with: [])

        #expect(cache.summary(for: 1, fallback: .notConfigured) == .notConfigured)
    }
}

@Suite("AppRuntimeOptions")
struct AppRuntimeOptionsTests {
    @Test("UI testing argument disables live wallpaper startup")
    func uiTestingArgumentDisablesLiveWallpaperStartup() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper", "--ui-testing"],
            environment: [:],
            isXCTestLoaded: false
        )

        #expect(options.shouldRestoreSavedWallpapers == false)
        #expect(options.shouldStartAutomation == false)
        #expect(options.shouldShowOnboarding == false)
    }

    @Test("XCTest host environment disables live wallpaper startup")
    func xctestEnvironmentDisablesLiveWallpaperStartup() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper"],
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            isXCTestLoaded: false
        )

        #expect(options.shouldRestoreSavedWallpapers == false)
        #expect(options.shouldStartAutomation == false)
        #expect(options.shouldShowOnboarding == false)
    }

    @Test("Test scheme environment disables live wallpaper startup")
    func testSchemeEnvironmentDisablesLiveWallpaperStartup() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper"],
            environment: ["LIVEWALLPAPER_TESTING": "1"],
            isXCTestLoaded: false
        )

        #expect(options.shouldRestoreSavedWallpapers == false)
        #expect(options.shouldStartAutomation == false)
        #expect(options.shouldShowOnboarding == false)
    }

    @Test("Loaded XCTest framework disables live wallpaper startup")
    func loadedXCTestFrameworkDisablesLiveWallpaperStartup() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper"],
            environment: [:],
            isXCTestLoaded: true
        )

        #expect(options.shouldRestoreSavedWallpapers == false)
        #expect(options.shouldStartAutomation == false)
        #expect(options.shouldShowOnboarding == false)
    }

    @Test("Launch startup plan relies on ScreenManager initial refresh")
    func launchStartupPlanAvoidsDuplicateScreenReloads() {
        let runtime = AppRuntimeOptions(
            arguments: ["LiveWallpaper"],
            environment: [:],
            isXCTestLoaded: false
        )

        let plan = AppStartupPlan(runtimeOptions: runtime, onboardingCompleted: true)

        #expect(plan.screenManagerOptions.restoreSavedWallpapers)
        #expect(plan.screenManagerOptions.startAutomation)
        #expect(plan.refreshScreensAfterManagerCreation == false)
        #expect(plan.reloadWallpapersAfterLaunch == false)
        #expect(plan.showOnboarding == false)
    }
}

@Suite("Menu bar playback controls")
@MainActor
struct MenuBarPlaybackControlTests {
    @Test("Toggle helper pauses a playing wallpaper exactly once")
    func togglePausesPlayingWallpaperOnce() {
        let playback = FakePlaybackController(isPlaying: true)

        PlaybackToggle.toggle(playback)

        #expect(!playback.isPlaying)
        #expect(playback.pauseCount == 1)
        #expect(playback.playCount == 0)
    }

    @Test("Toggle helper plays a paused wallpaper exactly once")
    func togglePlaysPausedWallpaperOnce() {
        let playback = FakePlaybackController(isPlaying: false)

        PlaybackToggle.toggle(playback)

        #expect(playback.isPlaying)
        #expect(playback.playCount == 1)
        #expect(playback.pauseCount == 0)
    }
}

@Suite("PlaylistEntry identity")
struct PlaylistEntryIdentityTests {
    @Test("Entry ID is deterministic and does not use process-randomized hashValue")
    func entryIDUsesStableBookmarkEncoding() {
        let bookmark = Data([0x01, 0x02, 0x03, 0x04])

        #expect(PlaylistEntry(bookmark: bookmark, isPrimary: true, isPlaying: false, name: "Primary").id == "p:AQIDBA==")
        #expect(PlaylistEntry(bookmark: bookmark, isPrimary: false, isPlaying: false, name: "Extra").id == "x:AQIDBA==")
    }
}

@Suite("WeatherReactivePolicy")
struct WeatherReactivePolicyTests {
    @Test("Monitor runs only when an active screen has weather-reactive effects")
    func monitorRequiresActiveWeatherReactiveConfiguration() {
        let activeID: CGDirectDisplayID = 10
        let inactiveID: CGDirectDisplayID = 20

        var activeConfig = ScreenConfiguration(screenID: activeID, videoBookmarkData: Data([0x01]))
        activeConfig.effectConfig.weatherReactive = true

        var inactiveConfig = ScreenConfiguration(screenID: inactiveID, videoBookmarkData: Data([0x02]))
        inactiveConfig.effectConfig.weatherReactive = true

        var disabledConfig = ScreenConfiguration(screenID: activeID, videoBookmarkData: Data([0x03]))
        disabledConfig.effectConfig.weatherReactive = false

        #expect(WeatherReactivePolicy.shouldMonitor(configurations: [activeConfig], activeScreenIDs: [activeID]))
        #expect(!WeatherReactivePolicy.shouldMonitor(configurations: [inactiveConfig], activeScreenIDs: [activeID]))
        #expect(!WeatherReactivePolicy.shouldMonitor(configurations: [disabledConfig], activeScreenIDs: [activeID]))
    }
}

@Suite("Monitoring reference counter")
struct MonitoringReferenceCounterTests {
    @Test("Monitoring stops only after every starter has stopped")
    func stopsAfterAllConsumersRelease() {
        var counter = MonitoringReferenceCounter()

        #expect(counter.start() == true)
        #expect(counter.start() == false)
        #expect(counter.stop() == false)
        #expect(counter.stop() == true)
        #expect(counter.stop() == false)
    }
}

@Suite("Estimated frame tick policy")
struct EstimatedFrameTickPolicyTests {
    @Test("Half-second tick count is derived from nominal FPS")
    func tickCountUsesNominalFPSWithFallback() {
        #expect(EstimatedFrameTickPolicy.tickCount(forFrameRate: 60, interval: 0.5) == 30)
        #expect(EstimatedFrameTickPolicy.tickCount(forFrameRate: 24, interval: 0.5) == 12)
        #expect(EstimatedFrameTickPolicy.tickCount(forFrameRate: 0, interval: 0.5) == 15)
    }
}

@Suite("Rain glass texture pool")
struct RainGlassTexturePoolTests {
    @Test("Pool reuses a bounded ring for matching dimensions")
    func poolReusesMatchingTextures() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = RainGlassTexturePool(device: device, inFlightTextureCount: 2)

        let first = try #require(pool.nextTexture(width: 64, height: 64))
        let second = try #require(pool.nextTexture(width: 64, height: 64))
        let third = try #require(pool.nextTexture(width: 64, height: 64))

        #expect(ObjectIdentifier(first as AnyObject) != ObjectIdentifier(second as AnyObject))
        #expect(ObjectIdentifier(first as AnyObject) == ObjectIdentifier(third as AnyObject))
    }

    @Test("Pool rebuilds when render dimensions change")
    func poolRebuildsForNewDimensions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = RainGlassTexturePool(device: device, inFlightTextureCount: 2)

        let first = try #require(pool.nextTexture(width: 64, height: 64))
        let resized = try #require(pool.nextTexture(width: 128, height: 64))

        #expect(first.width == 64)
        #expect(resized.width == 128)
        #expect(resized.height == 64)
    }
}

@Suite("Aerial thumbnail cache key")
struct AerialThumbnailCacheKeyTests {
    @Test("Key includes path so same file names in different folders stay separate")
    func keyIncludesPath() {
        let first = aerialAsset(url: URL(fileURLWithPath: "/tmp/a/scene.mov"), fileSize: 100)
        let second = aerialAsset(url: URL(fileURLWithPath: "/tmp/b/scene.mov"), fileSize: 100)

        #expect(AerialThumbnailCacheKey(asset: first) != AerialThumbnailCacheKey(asset: second))
    }

    @Test("Key includes file size so changed files invalidate cached thumbnails")
    func keyIncludesFileSize() {
        let original = aerialAsset(url: URL(fileURLWithPath: "/tmp/a/scene.mov"), fileSize: 100)
        let changed = aerialAsset(url: URL(fileURLWithPath: "/tmp/a/scene.mov"), fileSize: 200)

        #expect(AerialThumbnailCacheKey(asset: original) != AerialThumbnailCacheKey(asset: changed))
    }

    private func aerialAsset(url: URL, fileSize: Int64) -> AerialAsset {
        AerialAsset(
            id: url.deletingPathExtension().lastPathComponent,
            url: url,
            displayName: url.lastPathComponent,
            category: nil,
            fileSize: fileSize,
            bookmarkData: Data([0x01])
        )
    }
}

@Suite("HTML wallpaper local file access")
@MainActor
struct HTMLWallpaperLocalFileAccessTests {
    @Test("Single HTML files allow WebKit to read sibling assets")
    func singleFileReadAccessUsesParentDirectory() {
        let fileURL = URL(fileURLWithPath: "/tmp/site/index.html")

        #expect(HTMLWallpaperView.readAccessRoot(forFileURL: fileURL) == fileURL.deletingLastPathComponent())
    }
}

@Suite("HTML wallpaper mouse interaction")
@MainActor
struct HTMLWallpaperMouseInteractionTests {
    @Test("Interactive HTML wallpapers let the host window receive mouse events")
    func interactiveHTMLWallpapersLetHostWindowReceiveMouseEvents() {
        let session = AmbientWallpaperSessionBuilder().makeHTMLSession(
            source: .inline("<html><body></body></html>"),
            config: HTMLConfig(allowMouseInteraction: true),
            frame: CGRect(x: 0, y: 0, width: 16, height: 16)
        )
        defer { session.cleanup() }

        #expect(session.wallpaperWindow?.ignoresMouseEvents == false)
        // 抬到桌面图标层之上 (`desktopIcon + 1`) 是绕过 macOS Sonoma
        // "Click wallpaper to reveal desktop" 手势的关键 — 与 Plash 的 DesktopWindow 一致。
        #expect((session.wallpaperWindow?.level.rawValue ?? 0) == CGWindowLevelForKey(.desktopIconWindow) + 1)
        #expect(session.wallpaperWindow?.canBecomeKey == true)
    }

    @Test("Passive HTML wallpapers keep mouse events passing through")
    func passiveHTMLWallpapersKeepMouseEventsPassingThrough() {
        let session = AmbientWallpaperSessionBuilder().makeHTMLSession(
            source: .inline("<html><body></body></html>"),
            config: HTMLConfig(allowMouseInteraction: false),
            frame: CGRect(x: 0, y: 0, width: 16, height: 16)
        )
        defer { session.cleanup() }

        #expect(session.wallpaperWindow?.ignoresMouseEvents == true)
        #expect((session.wallpaperWindow?.level.rawValue ?? 0) == CGWindowLevelForKey(.desktopWindow) - 1)
    }
}

@Suite("WallpaperAutomationCoordinator")
@MainActor
struct WallpaperAutomationCoordinatorTests {
    @Test("Schedule handler runs once when monitoring starts")
    func scheduleHandlerRunsImmediately() async throws {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }

        let screen = Screen(nsScreen: nsScreen)
        let coordinator = WallpaperAutomationCoordinator()
        var calls = 0

        coordinator.start(
            screenProvider: { [screen] },
            configurationProvider: { _ in nil },
            scheduleHandler: { _ in calls += 1 },
            playlistHandler: { _ in }
        )

        for _ in 0..<10 where calls == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }

        coordinator.stop()

        #expect(calls == 1)
    }
}

@Suite("WallpaperVideoPlayer startup policy")
@MainActor
struct WallpaperVideoPlayerStartupPolicyTests {
    @Test("Pause before AVPlayer readiness suppresses ready-time autoplay")
    func pauseBeforeReadinessSuppressesAutoplay() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/missing.mov"),
            frame: CGRect(x: 0, y: 0, width: 16, height: 16),
            loadImmediately: false
        )

        #expect(player.shouldAutoplayWhenReady)

        player.pause()
        #expect(!player.shouldAutoplayWhenReady)

        player.play()
        #expect(player.shouldAutoplayWhenReady)
    }

    @Test("Frame-rate limit requested before AVPlayer item exists is retained")
    func frameRateLimitBeforeItemReadinessIsRetained() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/missing.mov"),
            frame: CGRect(x: 0, y: 0, width: 16, height: 16),
            loadImmediately: false
        )

        player.setFrameRateLimit(30)

        #expect(player.requestedFrameRateLimit == 30)
    }
}

@Suite("Monitoring cadence policy")
struct MonitoringCadencePolicyTests {
    @Test("GPU sampling runs immediately then at configured cadence")
    func gpuSamplingCadence() {
        #expect(MonitoringCadencePolicy.shouldSampleGPU(updateCount: 1, cadence: 3))
        #expect(!MonitoringCadencePolicy.shouldSampleGPU(updateCount: 2, cadence: 3))
        #expect(MonitoringCadencePolicy.shouldSampleGPU(updateCount: 3, cadence: 3))
        #expect(!MonitoringCadencePolicy.shouldSampleGPU(updateCount: 4, cadence: 3))
        #expect(MonitoringCadencePolicy.shouldSampleGPU(updateCount: 6, cadence: 3))
    }

    @Test("Cadence below two samples every update")
    func lowCadenceSamplesEveryUpdate() {
        #expect(MonitoringCadencePolicy.shouldSampleGPU(updateCount: 4, cadence: 1))
        #expect(MonitoringCadencePolicy.shouldSampleGPU(updateCount: 4, cadence: 0))
    }
}

@Suite("Wallpaper runtime readiness")
@MainActor
struct WallpaperRuntimeReadinessTests {
    @Test("Default preparation reports false when cancelled")
    func defaultPreparationCancellation() async {
        let session = FakePlaybackController(isPlaying: false)
        let task = Task { @MainActor in
            await session.prepareForDisplay(timeout: .milliseconds(200))
        }

        task.cancel()
        let prepared = await task.value

        #expect(!prepared)
    }
}

@MainActor
private final class FakePlaybackController: WallpaperPlaybackControllable {
    var isPlaying: Bool
    var playCount = 0
    var pauseCount = 0

    init(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }

    var wallpaperType: WallpaperType { .video }
    var summary: WallpaperSessionSummary { .notConfigured }
    var videoPlayer: WallpaperVideoPlayer? { nil }
    var wallpaperWindow: NSWindow? { nil }

    func show() {}
    func hide() {}
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {}
    func updateFrame(to frame: CGRect) {}
    func cleanup() {}

    func play() {
        playCount += 1
        isPlaying = true
    }

    func pause() {
        pauseCount += 1
        isPlaying = false
    }
}

@Suite("WallpaperConfigurationStore removing invalid video configurations")
struct WallpaperConfigurationStoreInvalidConfigTests {

    @Test("Invalid video configurations are removed while non-video wallpapers survive")
    func invalidVideoConfigurationsAreRemoved() {
        let configs = [
            ScreenConfiguration(screenID: 1, videoBookmarkData: Data([0x01]), wallpaperType: .video),
            ScreenConfiguration(screenID: 2, videoBookmarkData: Data(), wallpaperType: .html, htmlContent: "https://example.com"),
            ScreenConfiguration(screenID: 3, videoBookmarkData: Data(), wallpaperType: .metalShader, shaderPreset: .aurora),
        ]

        let pruned = WallpaperConfigurationStore.removingInvalidVideoConfigurations(
            from: configs,
            invalidScreenIDs: [1, 2, 3]
        )

        #expect(pruned.count == 2)
        #expect(pruned.contains(where: { $0.screenID == 2 && $0.wallpaperType == .html }))
        #expect(pruned.contains(where: { $0.screenID == 3 && $0.wallpaperType == .metalShader }))
        #expect(!pruned.contains(where: { $0.screenID == 1 }))
    }
}

@Suite("WallpaperPolicyEngine")
struct WallpaperPolicyEngineTests {

    @Test("On battery without pause-on-battery: profile stays quality; no pause requested")
    func batteryStaticProfile() {
        let settings = GlobalSettings(globalPauseOnBattery: false)

        let profile = WallpaperPolicyEngine.performanceProfile(
            globalSettings: settings,
            powerSource: .battery(level: 80),
            isHiddenByFullScreen: false
        )

        // Battery no longer produces a degraded-animation state — the UX is
        // static-on-battery, driven by `shouldPauseForPower` when enabled.
        #expect(profile == .quality)
        #expect(!WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: settings,
            powerSource: .battery(level: 80)
        ))
    }

    @Test("Fullscreen hidden screen maps to suspended profile")
    func fullScreenSuspendedProfile() {
        let settings = GlobalSettings(pauseOnFullScreen: true)

        let profile = WallpaperPolicyEngine.performanceProfile(
            globalSettings: settings,
            powerSource: .external,
            isHiddenByFullScreen: true
        )

        #expect(profile == .suspended)
        #expect(WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: settings,
            isHiddenByFullScreen: true
        ))
    }

    @Test("Global pause on battery pauses video playback")
    func globalPauseOnBatteryDecision() {
        let settings = GlobalSettings(globalPauseOnBattery: true)

        #expect(WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: settings,
            powerSource: .battery(level: 90)
        ))
        #expect(WallpaperPolicyEngine.shouldResumeFromPower(
            powerSource: .external,
            wasPausedByPower: true
        ))
    }

    @Test("Startup video pause combines power and fullscreen policy")
    func startupVideoPauseDecision() {
        #expect(WallpaperPolicyEngine.shouldStartVideoPaused(
            globalSettings: GlobalSettings(globalPauseOnBattery: true, pauseOnFullScreen: false),
            powerSource: .battery(level: 90),
            isHiddenByFullScreen: false
        ))
        #expect(WallpaperPolicyEngine.shouldStartVideoPaused(
            globalSettings: GlobalSettings(globalPauseOnBattery: false, pauseOnFullScreen: true),
            powerSource: .external,
            isHiddenByFullScreen: true
        ))
        #expect(!WallpaperPolicyEngine.shouldStartVideoPaused(
            globalSettings: GlobalSettings(globalPauseOnBattery: false, pauseOnFullScreen: true),
            powerSource: .external,
            isHiddenByFullScreen: false
        ))
    }

    @Test("Fullscreen resume waits when power policy still wants pause")
    func fullScreenResumeHonorsPowerPause() {
        let settings = GlobalSettings(globalPauseOnBattery: true, pauseOnFullScreen: true)

        #expect(!WallpaperPolicyEngine.shouldResumeFromFullScreen(
            globalSettings: settings,
            powerSource: .battery(level: 90),
            wasPausedByFullScreen: true
        ))
        #expect(WallpaperPolicyEngine.shouldResumeFromFullScreen(
            globalSettings: settings,
            powerSource: .external,
            wasPausedByFullScreen: true
        ))
    }

    @Test("Fullscreen fallback polling only runs when fullscreen policy can affect sessions")
    func fullScreenFallbackPollingDecision() {
        #expect(WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: true),
            hasConfiguredWallpaperSessions: true
        ))
        #expect(!WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: false),
            hasConfiguredWallpaperSessions: true
        ))
        #expect(!WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: true),
            hasConfiguredWallpaperSessions: false
        ))
    }
}

@Suite("FullScreenDetector adaptive polling")
@MainActor
struct FullScreenDetectorAdaptivePollingTests {

    @Test("Detector starts notification-only and toggles fallback polling explicitly")
    func fallbackPollingTogglesExplicitly() {
        let detector = FullScreenDetector(pollInterval: 60)

        #expect(!detector.isFallbackPollingEnabled)

        detector.setFallbackPollingEnabled(true)
        #expect(detector.isFallbackPollingEnabled)

        detector.setFallbackPollingEnabled(true)
        #expect(detector.isFallbackPollingEnabled)

        detector.setFallbackPollingEnabled(false)
        #expect(!detector.isFallbackPollingEnabled)

        detector.stop()
    }
}

@Suite("PlaylistPolicy")
struct PlaylistPolicyTests {

    @Test("Sequential cursor advances 0 → 1 → 2 → 0")
    func sequentialCursorAdvances() {
        // Covers the regression where the old primary-based API stalled after
        // one rotation when primary coincided with a playlist entry.
        let count = 3

        let step1 = PlaylistPolicy.nextCursor(currentCursor: 0, playlistCount: count, shuffle: false)
        let step2 = PlaylistPolicy.nextCursor(currentCursor: 1, playlistCount: count, shuffle: false)
        let step3 = PlaylistPolicy.nextCursor(currentCursor: 2, playlistCount: count, shuffle: false)

        #expect(step1 == 1)
        #expect(step2 == 2)
        #expect(step3 == 0)
    }

    @Test("Playlist with fewer than two entries does not rotate")
    func tooFewEntriesDoesNotRotate() {
        #expect(PlaylistPolicy.nextCursor(currentCursor: 0, playlistCount: 1, shuffle: false) == nil)
        #expect(PlaylistPolicy.nextCursor(currentCursor: 0, playlistCount: 0, shuffle: true) == nil)
    }

    @Test("Shuffle excludes the currently playing cursor")
    func shuffleExcludesCurrentCursor() {
        // randomIndex returns the current cursor → policy must bump to a
        // different index so we never replay the same video.
        let next = PlaylistPolicy.nextCursor(
            currentCursor: 2,
            playlistCount: 4,
            shuffle: true,
            randomIndex: { _ in 2 }
        )

        #expect(next != 2)
        #expect(next != nil)
    }

    @Test("Stale cursor (past end) normalizes before advancing")
    func staleCursorNormalizes() {
        // Persisted cursor 7 against a 3-entry playlist → normalize to 7 % 3 = 1,
        // advance to 2.
        let next = PlaylistPolicy.nextCursor(currentCursor: 7, playlistCount: 3, shuffle: false)
        #expect(next == 2)
    }

    @Test("combinedPlaylist returns nil when only primary exists")
    func combinedPlaylistNilWithOneEntry() {
        #expect(PlaylistPolicy.combinedPlaylist(primary: Data([0x01]), additional: nil) == nil)
        #expect(PlaylistPolicy.combinedPlaylist(primary: Data([0x01]), additional: []) == nil)
    }

    @Test("combinedPlaylist composes primary + additional when more than one entry")
    func combinedPlaylistComposes() {
        let primary = Data([0x01])
        let extras = [Data([0x02]), Data([0x03])]
        let combined = PlaylistPolicy.combinedPlaylist(primary: primary, additional: extras)
        #expect(combined == [primary, extras[0], extras[1]])
    }

    @Test("Playlist rotation waits until configured interval elapses")
    func playlistRotationInterval() {
        let lastRotation = Date(timeIntervalSince1970: 100)

        #expect(!PlaylistPolicy.shouldRotate(
            now: Date(timeIntervalSince1970: 159),
            lastRotation: lastRotation,
            rotationMinutes: 1
        ))
        #expect(PlaylistPolicy.shouldRotate(
            now: Date(timeIntervalSince1970: 160),
            lastRotation: lastRotation,
            rotationMinutes: 1
        ))
    }

    @Test("Sequential previousCursor decrements 2 → 1 → 0 → 2")
    func sequentialPreviousCursorDecrements() {
        #expect(PlaylistPolicy.previousCursor(currentCursor: 2, playlistCount: 3, shuffle: false) == 1)
        #expect(PlaylistPolicy.previousCursor(currentCursor: 1, playlistCount: 3, shuffle: false) == 0)
        #expect(PlaylistPolicy.previousCursor(currentCursor: 0, playlistCount: 3, shuffle: false) == 2)
    }

    @Test("Previous with fewer than two entries does not rotate")
    func previousTooFewEntries() {
        #expect(PlaylistPolicy.previousCursor(currentCursor: 0, playlistCount: 1, shuffle: false) == nil)
        #expect(PlaylistPolicy.previousCursor(currentCursor: 0, playlistCount: 0, shuffle: false) == nil)
    }

    @Test("Shuffle previous excludes the current cursor")
    func shufflePreviousExcludesCurrent() {
        let result = PlaylistPolicy.previousCursor(
            currentCursor: 2,
            playlistCount: 4,
            shuffle: true,
            randomIndex: { _ in 2 }
        )
        #expect(result != nil && result != 2)
    }

    @Test("Stale previousCursor (past end) normalizes before stepping back")
    func stalePreviousCursorNormalizes() {
        #expect(PlaylistPolicy.previousCursor(currentCursor: 7, playlistCount: 3, shuffle: false) == 0)
    }

    // MARK: - resolveCursor (used by ScreenManager.replacePlaylist after reorder)

    @Test("resolveCursor: active bookmark found at its new index")
    func resolveCursorFound() {
        let primary = Data([0x01])
        let extra1 = Data([0x02])
        let extra2 = Data([0x03])
        // After user reorders: [extra1, primary, extra2]
        let combined = [extra1, primary, extra2]
        // Was playing primary → cursor should follow primary to its new index 1.
        #expect(PlaylistPolicy.resolveCursor(activeBookmark: primary, in: combined) == 1)
    }

    @Test("resolveCursor: active bookmark removed from list → falls back to 0")
    func resolveCursorRemovedFallsBackToPrimary() {
        let primary = Data([0x01])
        let extra = Data([0x02])
        let removed = Data([0x99])
        let combined = [primary, extra]
        #expect(PlaylistPolicy.resolveCursor(activeBookmark: removed, in: combined) == 0)
    }

    @Test("resolveCursor: nil active → 0")
    func resolveCursorNilActive() {
        let combined = [Data([0x01]), Data([0x02])]
        #expect(PlaylistPolicy.resolveCursor(activeBookmark: nil, in: combined) == 0)
    }

    @Test("resolveCursor: empty combined → 0")
    func resolveCursorEmptyCombined() {
        #expect(PlaylistPolicy.resolveCursor(activeBookmark: Data([0x01]), in: []) == 0)
    }
}

// MARK: - ScreenConfiguration rotation / schedule / replace-primary integration

@Suite("ScreenConfiguration playlist + schedule helpers")
struct ScreenConfigurationHelpersTests {

    @Test("replacePrimaryVideo preserves effects/playlist/schedule")
    func replacePrimaryVideoPreservesSettings() {
        var effects = VideoEffectConfig.default
        effects.saturation = 0.7
        let oldBookmark = Data([0x01])
        let newBookmark = Data([0x99])

        var config = ScreenConfiguration(
            screenID: 1,
            videoBookmarkData: oldBookmark,
            particleEffect: .snow,
            effectConfig: effects,
            scheduleSlots: ScheduleSlot.defaultSlots,
            playlistBookmarks: [Data([0x02]), Data([0x03])],
            shufflePlaylist: true,
            playlistRotationMinutes: 15,
            playlistCursorIndex: 2
        )

        config.replacePrimaryVideo(bookmarkData: newBookmark)

        #expect(config.savedVideoBookmarkData == newBookmark)
        #expect(config.activeWallpaper == .video(bookmarkData: newBookmark))
        #expect(config.playlistCursorIndex == 0) // reset so cursor isn't stale
        // Everything else preserved:
        #expect(config.particleEffect == .snow)
        #expect(config.effectConfig.saturation == 0.7)
        #expect(config.scheduleSlots?.count == ScheduleSlot.defaultSlots.count)
        #expect(config.playlistBookmarks == [Data([0x02]), Data([0x03])])
        #expect(config.shufflePlaylist == true)
        #expect(config.playlistRotationMinutes == 15)
    }

    @Test("applyScheduledBookmark preserves savedVideoBookmarkData (primary)")
    func applyScheduledBookmarkPreservesPrimary() {
        let primary = Data([0x01])
        let scheduled = Data([0xAA])

        var config = ScreenConfiguration(
            screenID: 2,
            videoBookmarkData: primary,
            particleEffect: .rain,
            effectConfig: .default,
            playlistBookmarks: [Data([0xBB])],
            playlistCursorIndex: 1
        )

        config.applyScheduledBookmark(scheduled)

        #expect(config.activeWallpaper == .video(bookmarkData: scheduled))
        #expect(config.savedVideoBookmarkData == primary, "primary survives schedule")
        #expect(config.playlistCursorIndex == 1, "cursor survives schedule")
        #expect(config.particleEffect == .rain)
        #expect(config.playlistBookmarks == [Data([0xBB])])
    }

    @Test("withUpdatedActiveBookmark refreshes primary when cursor=0")
    func withUpdatedActiveBookmarkAtPrimary() {
        let config = ScreenConfiguration(
            screenID: 3,
            videoBookmarkData: Data([0x01]),
            playlistBookmarks: [Data([0x02])],
            playlistCursorIndex: 0
        )
        let refreshed = Data([0xFE])
        let updated = config.withUpdatedActiveBookmark(refreshed)
        #expect(updated.savedVideoBookmarkData == refreshed)
        #expect(updated.activeWallpaper == .video(bookmarkData: refreshed))
        #expect(updated.playlistBookmarks == [Data([0x02])]) // untouched
    }

    @Test("withUpdatedActiveBookmark refreshes the playlist slot it matches and leaves primary alone")
    func withUpdatedActiveBookmarkAtPlaylistSlot() {
        let primary = Data([0x01])
        let playlistEntry = Data([0x03])
        var config = ScreenConfiguration(
            screenID: 4,
            videoBookmarkData: primary,
            playlistBookmarks: [Data([0x02]), playlistEntry],
            playlistCursorIndex: 2
        )
        // Simulate "currently playing playlist[1]" — what advancePlaylist does.
        config.activeWallpaper = .video(bookmarkData: playlistEntry)

        let refreshed = Data([0xFE])
        let updated = config.withUpdatedActiveBookmark(refreshed)

        #expect(updated.savedVideoBookmarkData == primary, "primary must not be clobbered")
        #expect(updated.activeWallpaper == .video(bookmarkData: refreshed))
        #expect(updated.playlistBookmarks == [Data([0x02]), refreshed])
    }

    @Test("withUpdatedActiveBookmark refreshes the schedule slot it matches and leaves primary alone")
    func withUpdatedActiveBookmarkAtScheduleSlot() {
        let primary = Data([0x01])
        let scheduledBookmark = Data([0xAA])
        var config = ScreenConfiguration(
            screenID: 5,
            videoBookmarkData: primary,
            scheduleSlots: [
                ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: scheduledBookmark, label: "Morning")
            ]
        )
        // Simulate "currently playing the morning schedule slot".
        config.activeWallpaper = .video(bookmarkData: scheduledBookmark)

        let refreshed = Data([0xFE])
        let updated = config.withUpdatedActiveBookmark(refreshed)

        #expect(updated.savedVideoBookmarkData == primary, "primary must not be clobbered by stale schedule refresh")
        #expect(updated.activeWallpaper == .video(bookmarkData: refreshed))
        #expect(updated.scheduleSlots?.first?.videoBookmarkData == refreshed)
    }

    @Test("playlistCursorIndex survives Codable round-trip")
    func playlistCursorIndexRoundTrip() throws {
        let original = ScreenConfiguration(
            screenID: 5,
            videoBookmarkData: Data([0x01]),
            playlistBookmarks: [Data([0x02])],
            playlistCursorIndex: 1
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)
        #expect(decoded.playlistCursorIndex == 1)
    }

    @Test("activateSavedVideoWallpaper resets cursor to 0")
    func activateSavedVideoResetsCursor() {
        let primary = Data([0x01])
        var config = ScreenConfiguration(
            screenID: 6,
            videoBookmarkData: primary,
            playlistBookmarks: [Data([0x02])],
            playlistCursorIndex: 1
        )
        config.setHTMLWallpaper("https://example.com")
        _ = config.activateSavedVideoWallpaper()
        #expect(config.playlistCursorIndex == 0)
        #expect(config.activeWallpaper == .video(bookmarkData: primary))
    }

    @Test("switching to ambient wallpaper while scheduled keeps primary bookmark")
    func ambientSwitchPreservesPrimaryDuringSchedule() {
        let primary = Data([0x01])
        let scheduled = Data([0xAA])
        var config = ScreenConfiguration(screenID: 7, videoBookmarkData: primary)

        config.applyScheduledBookmark(scheduled)
        config.setShaderWallpaper(.aurora)

        #expect(config.savedVideoBookmarkData == primary)
        #expect(config.videoBookmarkData == primary)
    }

    @Test("activateSavedVideoWallpaper prefers saved primary over active scheduled video")
    func activateSavedVideoUsesPrimary() {
        let primary = Data([0x01])
        let scheduled = Data([0xAA])
        var config = ScreenConfiguration(screenID: 8, videoBookmarkData: primary)

        config.applyScheduledBookmark(scheduled)
        let restored = config.activateSavedVideoWallpaper()

        #expect(restored)
        #expect(config.activeWallpaper == .video(bookmarkData: primary))
        #expect(config.savedVideoBookmarkData == primary)
    }
}

@Suite("SchedulePolicy")
struct SchedulePolicyTests {

    @Test("Schedule policy returns active slot bookmark")
    func schedulePolicyReturnsBookmark() {
        let current = Data([0x01])
        let scheduled = Data([0x02])
        var configuration = ScreenConfiguration(
            screenID: 41,
            videoBookmarkData: current,
            scheduleSlots: [
                ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: scheduled, label: "Morning")
            ]
        )
        configuration.wallpaperMode = .schedule

        let result = SchedulePolicy.scheduledBookmark(in: configuration, hour: 8)

        #expect(result?.slot.label == "Morning")
        #expect(result?.bookmarkData == scheduled)
    }

    @Test("Schedule policy skips already active bookmark")
    func schedulePolicySkipsAlreadyActiveBookmark() {
        let bookmark = Data([0x01])
        var configuration = ScreenConfiguration(
            screenID: 42,
            videoBookmarkData: bookmark,
            scheduleSlots: [
                ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: bookmark, label: "Morning")
            ]
        )
        configuration.wallpaperMode = .schedule

        let result = SchedulePolicy.scheduledBookmark(in: configuration, hour: 8)

        #expect(result == nil)
    }

    @Test("Schedule policy applies a primary slot when current wallpaper is not video")
    func schedulePolicyAppliesPrimarySlotOverHTML() {
        let primary = Data([0x01])
        let slot = ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: primary, label: "Morning")
        var configuration = ScreenConfiguration(
            screenID: 43,
            wallpaper: .html(source: .url(URL(string: "https://example.com")!), config: .default),
            scheduleSlots: [slot],
            savedVideoBookmarkData: primary
        )
        configuration.wallpaperMode = .schedule

        let result = SchedulePolicy.decision(for: configuration, hour: 8)

        #expect(result == .applySlot(slot: slot, bookmarkData: primary))
    }

    // MARK: - decision mode-gate

    @Test("decision returns .none when wallpaperMode != .schedule even with active slot")
    func decisionGatedByMode() {
        let primary = Data([0x01])
        let scheduled = Data([0x02])
        var configuration = ScreenConfiguration(
            screenID: 50,
            videoBookmarkData: primary,
            scheduleSlots: [
                ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: scheduled, label: "Morning")
            ]
        )

        configuration.wallpaperMode = .single
        #expect(SchedulePolicy.decision(for: configuration, hour: 8) == .none)

        configuration.wallpaperMode = .playlist
        #expect(SchedulePolicy.decision(for: configuration, hour: 8) == .none)
    }

    // MARK: - hourRanges

    @Test("hourRanges: normal slot produces a single range")
    func hourRangesNormal() {
        let slot = ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")
        let ranges = SchedulePolicy.hourRanges(for: slot)
        #expect(ranges == [6..<12])
    }

    @Test("hourRanges: midnight wrap produces two ranges")
    func hourRangesMidnightWrap() {
        let slot = ScheduleSlot(startHour: 22, endHour: 6, label: "Night")
        let ranges = SchedulePolicy.hourRanges(for: slot)
        #expect(ranges == [22..<24, 0..<6])
    }

    @Test("hourRanges: zero-length slot returns empty")
    func hourRangesZeroLength() {
        let slot = ScheduleSlot(startHour: 8, endHour: 8, label: "Empty")
        #expect(SchedulePolicy.hourRanges(for: slot).isEmpty)
    }

    // MARK: - conflicts

    @Test("conflicts: overlapping normal slots are detected")
    func conflictsOverlap() {
        let slotA = ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")
        let slotB = ScheduleSlot(startHour: 10, endHour: 14, label: "Late Morning")
        #expect(SchedulePolicy.conflicts(slot: slotA, against: [slotB]) == Set([slotB.id]))
    }

    @Test("conflicts: adjacent slots do not conflict")
    func conflictsAdjacent() {
        let slotA = ScheduleSlot(startHour: 6, endHour: 12, label: "A")
        let slotB = ScheduleSlot(startHour: 12, endHour: 18, label: "B")
        #expect(SchedulePolicy.conflicts(slot: slotA, against: [slotB]).isEmpty)
    }

    @Test("conflicts: midnight-wrap slot overlaps an early-morning slot")
    func conflictsMidnightWrap() {
        let night = ScheduleSlot(startHour: 22, endHour: 6, label: "Night")
        let morning = ScheduleSlot(startHour: 4, endHour: 9, label: "Morning")
        #expect(SchedulePolicy.conflicts(slot: night, against: [morning]) == Set([morning.id]))
    }

    @Test("conflicts: empty slot conflicts with nobody")
    func conflictsEmptySlot() {
        let empty = ScheduleSlot(startHour: 8, endHour: 8, label: "Empty")
        let other = ScheduleSlot(startHour: 0, endHour: 24, label: "Wrap-disguise")
        #expect(SchedulePolicy.conflicts(slot: empty, against: [other]).isEmpty)
    }

    // MARK: - findFreeRange

    @Test("findFreeRange: returns longest contiguous gap")
    func findFreeRangeFindsGap() {
        let slots = [
            ScheduleSlot(startHour: 6, endHour: 9, label: "A"),
            ScheduleSlot(startHour: 14, endHour: 18, label: "B"),
        ]
        let gap = SchedulePolicy.findFreeRange(in: slots, minHours: 2)
        // Free segments: 0–6 (6h), 9–14 (5h), 18–24 (6h). Longest is 0–6 or 18–24, both 6h.
        #expect(gap != nil)
        #expect((gap?.end ?? 0) - (gap?.start ?? 0) >= 5)
    }

    @Test("findFreeRange: returns nil when no segment satisfies minHours")
    func findFreeRangeReturnsNil() {
        let slots = [ScheduleSlot(startHour: 0, endHour: 23, label: "AlmostFull")]
        // Only 23–24 = 1h free; minHours: 2 cannot fit.
        #expect(SchedulePolicy.findFreeRange(in: slots, minHours: 2) == nil)
    }

    @Test("findFreeRange: returns whole day when slots empty")
    func findFreeRangeAllFree() {
        let gap = SchedulePolicy.findFreeRange(in: [], minHours: 24)
        #expect(gap?.start == 0)
        #expect(gap?.end == 24)
    }
}

@Suite("Screen runtime ownership")
@MainActor
struct ScreenRuntimeOwnershipTests {

    @Test("Screen reads summary and cleanup state from installed runtime session")
    func screenUsesInstalledRuntimeSession() {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }

        let screen = Screen(nsScreen: nsScreen)
        let session = TestWallpaperRuntimeSession(
            summary: WallpaperSessionSummary(
                wallpaperType: .metalShader,
                activity: .active,
                supportsPlaybackControl: false,
                subtitle: "Aurora"
            ),
            wallpaperType: .metalShader
        )

        screen.installRuntimeSession(session)

        #expect(screen.wallpaperSessionSummary == session.summary)
        #expect(screen.activeWallpaperType == .metalShader)
        #expect(screen.videoPlayer == nil)

        screen.resetRuntimeSession()

        #expect(session.cleanupCallCount == 1)
        #expect(screen.wallpaperSessionSummary == .notConfigured)
        #expect(screen.activeWallpaperWindow == nil)
    }
}

@MainActor
private final class TestWallpaperRuntimeSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType
    let summary: WallpaperSessionSummary
    let videoPlayer: WallpaperVideoPlayer? = nil
    let wallpaperWindow: NSWindow? = nil
    private(set) var cleanupCallCount = 0

    init(summary: WallpaperSessionSummary, wallpaperType: WallpaperType) {
        self.summary = summary
        self.wallpaperType = wallpaperType
    }

    func updateFrame(to frame: CGRect) {}

    func show() {}

    func hide() {}

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {}

    func cleanup() {
        cleanupCallCount += 1
    }
}
