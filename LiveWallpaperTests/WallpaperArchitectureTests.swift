import AppKit
import Foundation
import Metal
import Testing
import WebKit
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
        #expect(displayNames[1] == "Inline web content")
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

    @Test("UI launch tests can request settings on launch without restoring wallpapers")
    func uiLaunchTestingCanOpenSettingsOnLaunch() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper", "--ui-testing", "--open-settings-for-ui-testing"],
            environment: [:],
            isXCTestLoaded: false
        )
        let plan = AppStartupPlan(runtimeOptions: options, onboardingCompleted: true)

        #expect(plan.screenManagerOptions.restoreSavedWallpapers == false)
        #expect(plan.screenManagerOptions.startAutomation == false)
        #expect(plan.showOnboarding == false)
        #expect(plan.showSettingsOnLaunch == true)
    }

    @Test("UI launch tests can request settings on launch through environment")
    func uiLaunchTestingCanOpenSettingsOnLaunchThroughEnvironment() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper", "--ui-testing"],
            environment: ["LIVEWALLPAPER_OPEN_SETTINGS": "1"],
            isXCTestLoaded: false
        )
        let plan = AppStartupPlan(runtimeOptions: options, onboardingCompleted: true)

        #expect(plan.showSettingsOnLaunch == true)
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
    /// Exercises the shipping toggle path (`ScreenManager.togglePlayback(for:)`,
    /// the one the menu bar calls) rather than a standalone helper copy.
    private func makeManager() -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry()
        ))
    }

    private func makeScreen(installing playback: FakePlaybackController) -> Screen? {
        guard let nsScreen = NSScreen.screens.first else { return nil }
        let screen = Screen(nsScreen: nsScreen)
        screen.installRuntimeSession(playback)
        return screen
    }

    @Test("Toggle pauses a playing wallpaper exactly once")
    func togglePausesPlayingWallpaperOnce() {
        let playback = FakePlaybackController(isPlaying: true)
        guard let screen = makeScreen(installing: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }

        makeManager().togglePlayback(for: screen)

        #expect(!playback.isPlaying)
        #expect(playback.pauseCount == 1)
        #expect(playback.playCount == 0)
    }

    @Test("Toggle plays a paused wallpaper exactly once")
    func togglePlaysPausedWallpaperOnce() {
        let playback = FakePlaybackController(isPlaying: false)
        guard let screen = makeScreen(installing: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }

        makeManager().togglePlayback(for: screen)

        #expect(playback.isPlaying)
        #expect(playback.playCount == 1)
        #expect(playback.pauseCount == 0)
    }

    @Test("Toggle reads intent, not playback: a policy-suspended (intends-to-play) wallpaper pauses")
    func toggleReadsIntentNotPlaybackState() {
        // Suppressed by a performance policy: not actually playing, but the
        // user still intends to play. Toggling must pause (flip intent off),
        // not "resume" by chasing the suppressed isPlaying state.
        let playback = FakePlaybackController(isPlaying: false, userIntendsToPlay: true)
        guard let screen = makeScreen(installing: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }

        makeManager().togglePlayback(for: screen)

        #expect(!playback.userIntendsToPlay)
        #expect(playback.pauseCount == 1)
        #expect(playback.playCount == 0)
    }
}

@Suite("PlaylistEntry identity")
struct PlaylistEntryIdentityTests {
    @Test("Two entries with the same bookmark but different indices get distinct IDs")
    func duplicateBookmarkAtDifferentIndicesDiverge() {
        let bookmark = Data([0x01, 0x02, 0x03, 0x04])
        let first = PlaylistEntry(
            id: "\(bookmark.base64EncodedString())::0",
            bookmark: bookmark, isPrimary: true, isPlaying: false, name: "A"
        )
        let second = PlaylistEntry(
            id: "\(bookmark.base64EncodedString())::1",
            bookmark: bookmark, isPrimary: false, isPlaying: false, name: "A copy"
        )
        #expect(first.id != second.id)
    }

    @Test("Entry ID is stable across primary/playing flips at the same index")
    func entryIDStableUnderFlagFlip() {
        let bookmark = Data([0x05, 0x06])
        let id = "\(bookmark.base64EncodedString())::2"
        let before = PlaylistEntry(id: id, bookmark: bookmark, isPrimary: false, isPlaying: false, name: "X")
        let after = PlaylistEntry(id: id, bookmark: bookmark, isPrimary: true, isPlaying: true, name: "X")
        #expect(before.id == after.id)
    }
}

@Suite("WeatherReactivePolicy")
struct WeatherReactivePolicyTests {
    @Test("Weather refresh cadence is one hour")
    @MainActor
    func weatherRefreshCadenceIsHourly() {
        #expect(WeatherReactiveService.refreshInterval == .seconds(3600))
    }

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

@Suite("HTML folder URL scheme")
@MainActor
struct HTMLFolderURLSchemeTests {
    @Test("Folder scheme rejects traversal outside the granted folder")
    func rejectsTraversalOutsideGrantedFolder() throws {
        let fixture = try makeFolderFixture()
        let handler = FolderURLSchemeHandler()
        handler.folderURL = fixture.folder

        let task = CapturingURLSchemeTask(
            url: URL(string: "livewallpaper://wallpaper/%2e%2e/secret.txt")!,
            mainDocumentURL: makeTopLevelURL(handler: handler)
        )

        handler.webView(WKWebView(), start: task)

        #expect(task.failure != nil)
        #expect(task.receivedData.isEmpty)
    }

    @Test("Folder scheme rejects symlinks that resolve outside the granted folder")
    func rejectsSymlinkEscapes() throws {
        let fixture = try makeFolderFixture()
        let symlink = fixture.folder.appendingPathComponent("linked-secret.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.secret)
        let handler = FolderURLSchemeHandler()
        handler.folderURL = fixture.folder

        let task = CapturingURLSchemeTask(
            url: URL(string: "livewallpaper://wallpaper/linked-secret.txt")!,
            mainDocumentURL: makeTopLevelURL(handler: handler)
        )

        handler.webView(WKWebView(), start: task)

        #expect(task.failure != nil)
        #expect(task.receivedData.isEmpty)
    }

    @Test("Folder scheme sends large assets in bounded chunks")
    func sendsLargeAssetsInBoundedChunks() async throws {
        let fixture = try makeFolderFixture()
        let largeFile = fixture.folder.appendingPathComponent("large.bin")
        let payload = Data(repeating: 0xA5, count: 200 * 1024)
        try payload.write(to: largeFile)
        let handler = FolderURLSchemeHandler()
        handler.folderURL = fixture.folder

        let task = CapturingURLSchemeTask(
            url: URL(string: "livewallpaper://wallpaper/large.bin")!,
            mainDocumentURL: makeTopLevelURL(handler: handler)
        )

        handler.webView(WKWebView(), start: task)

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while task.didFinishCallCount == 0, task.failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(task.failure == nil)
        #expect(task.didFinishCallCount == 1)
        #expect(task.receivedData.count > 1)
        #expect(task.receivedData.allSatisfy { $0.count <= 64 * 1024 })
        #expect(task.receivedData.reduce(0) { $0 + $1.count } == payload.count)
    }

    /// Carries the handler's current session nonce so subresource requests skip the top-level nonce gate.
    private func makeTopLevelURL(handler: FolderURLSchemeHandler) -> URL {
        let nonce = handler.currentSessionNonce ?? ""
        return URL(string: "livewallpaper://wallpaper/index.html?n=\(nonce)")!
    }

    private func makeFolderFixture() throws -> (root: URL, folder: URL, secret: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaperSchemeTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let secret = root.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        return (root, folder, secret)
    }
}

@Suite("HTML navigation policy")
struct HTMLNavigationPolicyTests {
    @Test("Same-origin comparison includes scheme host and effective port")
    func sameOriginIncludesSchemeHostAndPort() {
        let current = URL(string: "https://example.com/path")!

        #expect(HTMLWallpaperView.isSameOrigin(navigationURL: URL(string: "https://example.com/next")!, current: current))
        #expect(!HTMLWallpaperView.isSameOrigin(navigationURL: URL(string: "http://example.com/next")!, current: current))
        #expect(!HTMLWallpaperView.isSameOrigin(navigationURL: URL(string: "https://example.com:8443/next")!, current: current))
        #expect(!HTMLWallpaperView.isSameOrigin(navigationURL: URL(string: "https://other.example.com/next")!, current: current))
    }

    @Test("Only HTTP and HTTPS links may be opened externally")
    func externalOpeningIsRestrictedToHTTPAndHTTPS() {
        #expect(HTMLWallpaperView.isExternallyOpenableURL(URL(string: "https://example.com")!))
        #expect(HTMLWallpaperView.isExternallyOpenableURL(URL(string: "http://example.com")!))
        #expect(!HTMLWallpaperView.isExternallyOpenableURL(URL(string: "file:///etc/passwd")!))
        #expect(!HTMLWallpaperView.isExternallyOpenableURL(URL(string: "javascript:alert(1)")!))
        #expect(!HTMLWallpaperView.isExternallyOpenableURL(URL(string: "livewallpaper://wallpaper/index.html")!))
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

private final class CapturingURLSchemeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private(set) var responses: [URLResponse] = []
    private(set) var receivedData: [Data] = []
    private(set) var didFinishCallCount = 0
    private(set) var failure: Error?

    init(url: URL, mainDocumentURL: URL? = nil) {
        var request = URLRequest(url: url)
        request.mainDocumentURL = mainDocumentURL
        self.request = request
    }

    func didReceive(_ response: URLResponse) {
        responses.append(response)
    }

    func didReceive(_ data: Data) {
        receivedData.append(data)
    }

    func didFinish() {
        didFinishCallCount += 1
    }

    func didFailWithError(_ error: any Error) {
        failure = error
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

    @Test("Existing local files without security scope are treated as media, not permission failures")
    func localFileWithoutSecurityScopeDoesNotReportAccessDenied() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-local-access-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = WallpaperVideoPlayer(
            url: url,
            frame: CGRect(x: 0, y: 0, width: 16, height: 16)
        )
        defer { player.cleanup() }

        if case .fileAccessDenied(url) = player.runtimeError {
            Issue.record("Existing app-owned video copies should continue to media validation, not fail as sandbox-denied: \(url.path)")
        }
    }

    @Test("Pause does not depend on AVPlayer already being in the playing state")
    func pauseIsNotGatedOnPlayingTimeControlStatus() throws {
        let source = try Self.readSourceFile("LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift")

        #expect(!source.contains("timeControlStatus == .playing else { return }"))
    }

    @Test("Wallpaper playback does not keep the display awake")
    func wallpaperPlaybackDisablesDisplaySleepPrevention() throws {
        let source = try Self.readSourceFile("LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift")

        #expect(source.contains("preventsDisplaySleepDuringVideoPlayback = false"))
    }

    @Test("Video preview surfaces controller errors in the preview UI")
    func videoPreviewSurfacesControllerErrors() throws {
        let source = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/VideoPreviewSection.swift")

        #expect(source.contains("previewController.lastError"))
    }

    @Test("Scene preview does not synchronously render a live poster on MainActor")
    func scenePreviewUsesNextFramePosterCapture() throws {
        let source = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/WPESceneDetailView.swift")

        #expect(source.contains("captureLivePosterFromNextFrame"))
        #expect(!source.contains("renderer.captureLivePoster()"))
    }

    @Test("Scene preview poster readback waits for present completion without synchronizing draw")
    func scenePreviewPosterReadbackUsesPresentCompletion() throws {
        let source = try Self.readSourceFile("LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift")
        let executor = try Self.readSourceFile("LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift")

        #expect(source.contains("capturePendingLivePostersAfterPresent"))
        #expect(source.contains("presentCompletion:"))
        #expect(executor.contains("presentCompletion: (@Sendable (MTLTexture, MTLCommandBuffer, @escaping @Sendable () -> Void) -> Void)? = nil"))
        #expect(executor.contains("presentCompletion(completionSource.texture, cb, releaseSource)"))
        #expect(source.contains("releaseSource:"))
        #expect(!source.contains("withSynchronizedLivePosterFrameIfNeeded"))
    }

    @Test("Puppet bound-scan cache stores successful nil checks")
    func puppetBoundScanCacheStoresSuccessfulNilChecks() throws {
        let executor = try Self.readSourceFile("LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift")

        #expect(executor.contains("struct PuppetBoundScanCacheEntry"))
        #expect(executor.contains("puppetBoundScanDetailByObjectID[objectID] = PuppetBoundScanCacheEntry"))
        #expect(!executor.contains("private var puppetBoundScanDetailByObjectID: [String: String?]"))
    }

    @Test("Scene detail fallback preview is a bounded static poster and releases ImageIO state")
    func sceneDetailPreviewFallbackDoesNotRetainAnimatedPreviewState() throws {
        let detail = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/WPESceneDetailView.swift")
        let preview = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/WPEPreviewView.swift")

        #expect(preview.contains("case staticPoster"))
        #expect(detail.contains("playbackMode: .staticPoster"))
        #expect(preview.contains("static func dismantleNSView"))
        #expect(preview.contains("context.coordinator.cancelInflight()"))
        #expect(preview.contains("nsView.clearImage()"))
        #expect(preview.contains("WPEPreviewImageDecodeBudget"))
        #expect(preview.contains("kCGImageSourceShouldCache"))
    }

    @Test("Scene preview keeps abnormal poster ratios inside the screen frame")
    func scenePreviewFitsAbnormalPosterRatiosInsideScreenFrame() throws {
        let detail = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/WPESceneDetailView.swift")

        #expect(detail.contains("GeometryReader"))
        #expect(detail.contains("screenPreviewSize"))
        #expect(detail.contains(".aspectRatio(contentMode: .fit)"))
        #expect(!detail.contains(".aspectRatio(contentMode: .fill)"))
    }

    private static func readSourceFile(_ relativePath: String) throws -> String {
        let bases = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ]

        guard let url = bases
            .lazy
            .map({ $0.appendingPathComponent(relativePath) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            Issue.record("Could not locate \(relativePath)")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
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

@Suite("Monitoring start policy")
struct MonitoringStartPolicyTests {
    @Test("Initial resource sample is deferred past sidebar expansion animation")
    func initialResourceSampleIsDeferredPastSidebarExpansionAnimation() {
        #expect(MonitoringStartPolicy.initialSampleDelay == .milliseconds(350))
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
    private(set) var userIntendsToPlay: Bool
    var playCount = 0
    var pauseCount = 0

    init(isPlaying: Bool, userIntendsToPlay: Bool? = nil) {
        self.isPlaying = isPlaying
        self.userIntendsToPlay = userIntendsToPlay ?? isPlaying
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
        userIntendsToPlay = true
        isPlaying = true
    }

    func pause() {
        pauseCount += 1
        userIntendsToPlay = false
        isPlaying = false
    }
}

@Suite("WallpaperConfigurationStore removing invalid resource configurations")
struct WallpaperConfigurationStoreInvalidConfigTests {

    @Test("Invalid local HTML configurations are removed while shader wallpapers survive")
    func invalidLocalHTMLConfigurationsAreRemoved() {
        let configs = [
            ScreenConfiguration(screenID: 1, videoBookmarkData: Data([0x01]), wallpaperType: .video),
            ScreenConfiguration(
                screenID: 2,
                wallpaper: .html(source: .file(bookmarkData: Data([0x02])), config: .default)
            ),
            ScreenConfiguration(screenID: 3, videoBookmarkData: Data(), wallpaperType: .metalShader, shaderPreset: .aurora),
        ]

        let pruned = WallpaperConfigurationStore.removingInvalidResourceConfigurations(
            from: configs,
            invalidScreenIDs: [1, 2, 3]
        )

        #expect(pruned.count == 1)
        #expect(pruned.first?.screenID == 3)
        #expect(pruned.first?.wallpaperType == .metalShader)
    }
}

@Suite("WallpaperPolicyEngine")
struct WallpaperPolicyEngineTests {

    @Test("On battery without pause-on-battery: profile stays quality; no pause requested")
    func batteryStaticProfile() {
        let settings = GlobalSettings(globalPauseOnBattery: false)

        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(powerSource: .battery(level: 80)),
            settings: settings
        )

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
            inputs: .test(isHiddenByFullScreen: true),
            settings: settings
        )

        #expect(profile == .suspended)
        #expect(WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: settings,
            isHiddenByFullScreen: true
        ))
    }

    @Test("User absence (lock / display-sleep / system-sleep) maps to suspended profile")
    func userAbsentSuspendedProfile() {
        let settings = GlobalSettings()

        let active = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isUserAbsent: false),
            settings: settings
        )
        let absent = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isUserAbsent: true),
            settings: settings
        )

        #expect(active == .quality)
        #expect(absent == .suspended)
    }

    @Test("Every suspend condition independently maps to suspended; all-benign stays quality")
    func unifiedSuspendConditionMatrix() {
        // Each row toggles exactly one condition true on an otherwise-benign
        // baseline (external power, nominal thermal, nothing hidden).
        func profile(
            hidden: Bool = false,
            occluding: Bool = false,
            appRule: Bool = false,
            game: Bool = false,
            thermal: ProcessInfo.ThermalState = .nominal,
            powerSource: PowerMonitor.PowerSource = .external,
            userAbsent: Bool = false,
            memoryPressure: Bool = false
        ) -> WallpaperPerformanceProfile {
            WallpaperPolicyEngine.performanceProfile(
                inputs: .test(
                    powerSource: powerSource,
                    isHiddenByFullScreen: hidden,
                    isWindowOccluding: occluding,
                    isApplicationRuleActive: appRule,
                    thermalState: thermal,
                    isGameModeActive: game,
                    isUserAbsent: userAbsent,
                    isUnderMemoryPressure: memoryPressure
                ),
                settings: GlobalSettings(
                    globalPauseOnBattery: true,
                    pauseOnFullScreen: true,
                    pauseInGameMode: true,
                    pauseOnWindowOcclusion: true
                )
            )
        }

        #expect(profile() == .quality)
        #expect(profile(hidden: true) == .suspended)
        #expect(profile(occluding: true) == .suspended)
        #expect(profile(appRule: true) == .suspended)
        #expect(profile(game: true) == .suspended)
        #expect(profile(thermal: .serious) == .suspended)
        #expect(profile(thermal: .critical) == .suspended)
        #expect(profile(powerSource: .battery(level: 50)) == .suspended)
        #expect(profile(userAbsent: true) == .suspended)
        #expect(profile(memoryPressure: true) == .suspended)
    }

    @Test("Global pause on battery pauses video playback")
    func globalPauseOnBatteryDecision() {
        let settings = GlobalSettings(globalPauseOnBattery: true)

        #expect(WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: settings,
            powerSource: .battery(level: 90)
        ))
    }

    @Test("Fullscreen fallback polling only runs when fullscreen policy can affect sessions")
    func fullScreenFallbackPollingDecision() {
        #expect(WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: true),
            hasConfiguredWallpaperSessions: true,
            hasConfiguredSceneSessions: false
        ))
        // pauseOnWindowOcclusion defaults on and alone keeps the poll alive.
        #expect(WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: false),
            hasConfiguredWallpaperSessions: true,
            hasConfiguredSceneSessions: false
        ))
        #expect(!WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: false, pauseOnWindowOcclusion: false),
            hasConfiguredWallpaperSessions: true,
            hasConfiguredSceneSessions: false
        ))
        #expect(!WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: true),
            hasConfiguredWallpaperSessions: false,
            hasConfiguredSceneSessions: false
        ))
        // Adaptive frame rate reads the occlusion fraction, so it needs the
        // fallback poll when both pause toggles are off — but only when a scene
        // session is live (it never throttles video/HTML).
        #expect(WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: false, adaptiveFrameRateEnabled: true),
            hasConfiguredWallpaperSessions: true,
            hasConfiguredSceneSessions: true
        ))
        #expect(!WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: false, pauseOnWindowOcclusion: false, adaptiveFrameRateEnabled: true),
            hasConfiguredWallpaperSessions: true,
            hasConfiguredSceneSessions: false
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
        let combined = [extra1, primary, extra2]
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
        #expect(config.playlistCursorIndex == 0)
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
        #expect(updated.playlistBookmarks == [Data([0x02])])
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
        let slot = ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: scheduled, label: "Morning")
        var configuration = ScreenConfiguration(
            screenID: 41,
            videoBookmarkData: current,
            scheduleSlots: [slot]
        )
        configuration.wallpaperMode = .schedule

        let result = SchedulePolicy.decision(for: configuration, hour: 8)

        #expect(result == .applySlot(slot: slot, bookmarkData: scheduled))
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

        let result = SchedulePolicy.decision(for: configuration, hour: 8)

        #expect(result == .none)
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
        #expect(gap != nil)
        #expect((gap?.end ?? 0) - (gap?.start ?? 0) >= 5)
    }

    @Test("findFreeRange: returns nil when no segment satisfies minHours")
    func findFreeRangeReturnsNil() {
        let slots = [ScheduleSlot(startHour: 0, endHour: 23, label: "AlmostFull")]
        #expect(SchedulePolicy.findFreeRange(in: slots, minHours: 2) == nil)
    }

    @Test("findFreeRange: returns whole day when slots empty")
    func findFreeRangeAllFree() {
        let gap = SchedulePolicy.findFreeRange(in: [], minHours: 24)
        #expect(gap?.start == 0)
        #expect(gap?.end == 24)
    }

    @Test("findFreeRange: detects cross-midnight wrap when it is the longest gap")
    func findFreeRangeWrapsMidnight() {
        let slots = [
            ScheduleSlot(startHour: 4, endHour: 7, label: "A"),
            ScheduleSlot(startHour: 8, endHour: 22, label: "B"),
        ]
        let gap = SchedulePolicy.findFreeRange(in: slots, minHours: 2)
        #expect(gap?.start == 22)
        #expect(gap?.end == 28)
        #expect((gap?.end ?? 0) % 24 == 4)
    }

    @Test("findFreeRange: prefers a longer linear gap over a shorter wrap gap")
    func findFreeRangeLinearOverWrap() {
        let slots = [
            ScheduleSlot(startHour: 1, endHour: 5, label: "A"),
            ScheduleSlot(startHour: 8, endHour: 23, label: "B"),
        ]
        let gap = SchedulePolicy.findFreeRange(in: slots, minHours: 2)
        #expect(gap?.start == 5)
        #expect(gap?.end == 8)
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

    @Test("Refreshing without preserving sessions cleans up connected screen sessions")
    func refreshWithoutPreservingSessionsCleansUpConnectedSessions() {
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false
        ))
        guard let screen = manager.screens.first else {
            Issue.record("No screen available for test")
            return
        }
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

        manager.refreshScreens(preserveRuntimeSessions: false)

        #expect(session.cleanupCallCount == 1)
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

// MARK: - Infrastructure ↔ Runtime boundary (ADR-002, step 1)

/// Fitness function standing in for the compile-time boundary the single app
/// target cannot enforce: `Infrastructure/` must not reach into types declared
/// under `Runtime/`. It freezes today's crossings as an explicit baseline and
/// fails on any *new* one, so the coupling can only be paid down over time.
@Suite("Infrastructure↔Runtime boundary")
struct InfrastructureRuntimeBoundaryTests {

    /// Known Infra→Runtime references, frozen at the ADR-002 baseline. This map
    /// may only ever *shrink*: deleting entries as the coupling is paid down is
    /// expected; adding one means a new boundary violation slipped in.
    private static let baseline: [String: Set<String>] = [
        "WPEDependencyMountResolver.swift": ["WPEPathSafety"],
        "WPEDirectorySceneAssetProvider.swift": ["WPEPathSafety"],
        "WPEDownloadArchiveReclaimer.swift": ["WPEPathSafety"],
        "WPEMetalTextureLoader.swift": [
            "WPEMetalTextureMetadataRegistry",
            "WPETexAnimatedFrame",
            "WPETexAnimatedTextureSource",
            "WPETexLazyAnimatedTextureSource",
            "WPEVideoTextureSource",
        ],
        "WPEMultiRootResourceResolver.swift": [
            "WPEResolutionAttempt",
            "WPEResolutionEvent",
            "WPEResolutionOrigin",
            "WPEResolutionOutcome",
            "WPEResolutionTracer",
        ],
        "WPERenderGraphBuilder.swift": ["WPEMetalRenderExecutor", "WPEResolutionTracer"],
        "WPERenderPipelineBuilder.swift": ["WPEResolutionTracer", "WPEShaderBuiltinMacros"],
        "WPESceneDebugArtifacts.swift": ["WPEResolutionDiagnosticsSnapshot"],
        "WPESceneProjectSchemaLoader.swift": ["WPEPathSafety"],
        "WPEStorageInventory.swift": ["WPEPathSafety"],
        "WPEStoragePaths.swift": ["WPEPathSafety"],
        "WPEVideoTextureDiskCache.swift": ["WPEPathSafety"],
        "WallpaperEngineCache.swift": ["WPEPathSafety"],
        "WallpaperEngineImportService.swift": ["HTMLWallpaperCompatibilityPolicy", "WPEPathSafety"],
        "WallpaperEngineLibraryScanner.swift": ["WPEPathSafety"],
        "WallpaperEngineProject.swift": ["WPEPathSafety"],
        "Workshop/Doctor/SteamCMDDoctorService.swift": ["WPEPathSafety"],
    ]

    @Test("Infrastructure/ introduces no Runtime/ references beyond the ADR-002 baseline")
    func infrastructureDoesNotReferenceRuntimeTypesBeyondBaseline() throws {
        let runtimeTypes = try runtimeDeclaredTypeNames()
        #expect(!runtimeTypes.isEmpty, "Runtime type extraction found nothing — scan is misconfigured")

        var newCrossings: [String] = []
        for file in try infrastructureSwiftFiles() {
            let relativePath = file.path.replacingOccurrences(
                of: infrastructureRoot.path + "/",
                with: ""
            )
            let code = stripComments(try String(contentsOf: file, encoding: .utf8))
            let allowed = Self.baseline[relativePath] ?? []

            for type in runtimeTypes where !allowed.contains(type) {
                guard containsIdentifier(type, in: code) else { continue }
                newCrossings.append("\(relativePath) references Runtime type \(type)")
            }
        }

        #expect(
            newCrossings.isEmpty,
            Comment(rawValue: """
            New Infrastructure→Runtime coupling (ADR-002 forbids growth):
            \(newCrossings.sorted().joined(separator: "\n"))
            """)
        )
    }

    @Test("Boundary baseline stays honest — no stale entries")
    func baselineHasNoStaleEntries() throws {
        let runtimeTypes = try runtimeDeclaredTypeNames()
        var stale: [String] = []

        for (relativePath, allowed) in Self.baseline {
            let file = infrastructureRoot.appendingPathComponent(relativePath)
            guard let code = try? String(contentsOf: file, encoding: .utf8) else {
                stale.append("\(relativePath) (file no longer exists)")
                continue
            }
            let stripped = stripComments(code)
            for type in allowed where !runtimeTypes.contains(type) || !containsIdentifier(type, in: stripped) {
                stale.append("\(relativePath): \(type)")
            }
        }

        #expect(
            stale.isEmpty,
            Comment(rawValue: """
            Baseline lists crossings that no longer exist — shrink the allow-list (ADR-002 lets it only shrink):
            \(stale.sorted().joined(separator: "\n"))
            """)
        )
    }

    // MARK: - Repository source scanning

    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "LiveWallpaperTests" {
            url.deleteLastPathComponent()
        }
        return url.deletingLastPathComponent()
    }

    private var infrastructureRoot: URL {
        repoRoot.appendingPathComponent("LiveWallpaper/Infrastructure")
    }

    private func infrastructureSwiftFiles() throws -> [URL] {
        try swiftFiles(under: infrastructureRoot)
    }

    private func runtimeDeclaredTypeNames() throws -> Set<String> {
        let declaration = /^(?:public |internal |private |fileprivate |open )*(?:final )?(?:class|struct|enum|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/
        var names: Set<String> = []
        for file in try swiftFiles(under: repoRoot.appendingPathComponent("LiveWallpaper/Runtime")) {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
                if let match = try declaration.prefixMatch(in: line) {
                    names.insert(String(match.output.1))
                }
            }
        }
        return names
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var collected: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegular { collected.append(url) }
        }
        return collected
    }

    /// Whole-word (`\b…\b`) identifier search — a substring hit inside a longer
    /// identifier (e.g. `WPEPath` inside `WPEPathSafety`) must not count.
    private func containsIdentifier(_ identifier: String, in source: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        func isIdentifierCharacter(_ character: Character) -> Bool {
            character == "_" || character.isLetter || character.isNumber
        }
        var searchStart = source.startIndex
        while let range = source.range(of: identifier, range: searchStart..<source.endIndex) {
            let boundaryBefore = range.lowerBound == source.startIndex
                || !isIdentifierCharacter(source[source.index(before: range.lowerBound)])
            let boundaryAfter = range.upperBound == source.endIndex
                || !isIdentifierCharacter(source[range.upperBound])
            if boundaryBefore && boundaryAfter { return true }
            searchStart = range.upperBound
        }
        return false
    }

    // MARK: - Comment stripping (so a type named only in prose never trips the scan)

    private func stripComments(_ source: String) -> String {
        stripLineComments(stripBlockComments(source))
    }

    private func stripBlockComments(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        var inString = false
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if inString {
                result.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                index = next
            } else if character == "\"" {
                inString = true
                result.append(character)
                index = next
            } else if character == "/", next < source.endIndex, source[next] == "*" {
                index = source.index(after: next)
                while index < source.endIndex {
                    if source[index] == "*",
                       source.index(after: index) < source.endIndex,
                       source[source.index(after: index)] == "/" {
                        index = source.index(index, offsetBy: 2)
                        break
                    }
                    index = source.index(after: index)
                }
            } else {
                result.append(character)
                index = next
            }
        }
        return result
    }

    private func stripLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let commentStart = lineCommentStart(in: line) else { return line }
                return line[line.startIndex..<commentStart]
            }
            .joined(separator: "\n")
    }

    private func lineCommentStart(in line: Substring) -> Substring.Index? {
        var inString = false
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if inString && character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString && character == "/" {
                let next = line.index(after: index)
                if next < line.endIndex && line[next] == "/" {
                    return index
                }
            }
            index = line.index(after: index)
        }
        return nil
    }
}
