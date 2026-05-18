import AppKit
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Protocolized ScreenManager dependencies")
@MainActor
struct ProtocolizedDependenciesTests {

    @Test("Initial refresh uses injected DisplayRegistering")
    func initialRefreshUsesInjectedDisplayRegistry() {
        guard let screen = Self.makeScreen() else {
            Issue.record("No NSScreen available for dependency injection test")
            return
        }
        let displayRegistry = FakeDisplayRegistry(screens: [screen])

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: displayRegistry
        ))

        #expect(manager.screens.map(\.id) == [screen.id])
        #expect(displayRegistry.currentScreensCallCount >= 1)
    }

    @Test("Explicit refresh reuses injected DisplayRegistering")
    func explicitRefreshReusesInjectedDisplayRegistry() {
        guard let screen = Self.makeScreen() else {
            Issue.record("No NSScreen available for dependency injection test")
            return
        }
        let displayRegistry = FakeDisplayRegistry(screens: [screen])
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: displayRegistry
        ))

        let initialCount = displayRegistry.currentScreensCallCount
        manager.refreshScreens()

        #expect(displayRegistry.currentScreensCallCount > initialCount)
        #expect(manager.screens.map(\.id) == [screen.id])
    }

    @Test("Startup full-screen pass uses injected FullScreenDetecting")
    func startupFullScreenPassUsesInjectedDetector() {
        guard let screen = Self.makeScreen() else {
            Issue.record("No NSScreen available for dependency injection test")
            return
        }
        let fullScreenDetector = FakeFullScreenDetector(hiddenScreens: [screen.id: true])

        _ = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: fullScreenDetector,
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen])
        ))

        #expect(fullScreenDetector.checkNowCallCount >= 1)
    }

    @Test("Power monitoring setup subscribes injected PowerMonitoring")
    func powerMonitoringSetupSubscribesInjectedMonitor() {
        let powerMonitor = FakePowerMonitor(initialPowerSource: .battery(level: 0.42))
        _ = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: powerMonitor,
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry()
        ))

        #expect(powerMonitor.powerSourcePublisherReadCount >= 1)
        #expect(powerMonitor.currentPowerSourceReadCount >= 1)
    }

    @Test("Video selection validates through injected PlayableVideoLoading")
    func videoSelectionUsesInjectedPlayableVideoLoader() async throws {
        guard let screen = Self.makeScreen() else {
            Issue.record("No NSScreen available for dependency injection test")
            return
        }
        let loader = FakePlayableVideoLoader(validationError: .validationFailed)
        let displayRegistry = FakeDisplayRegistry(screens: [screen])
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: loader,
            displayRegistry: displayRegistry
        ))
        guard let liveScreen = manager.screens.first else {
            Issue.record("Injected display registry did not produce a screen")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtocolizedDependencies-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not actually decoded by the fake".utf8).write(to: url)

        manager.setVideo(url: url, bookmarkData: Data([0x01, 0x02]), for: liveScreen)

        try await Self.waitUntil(timeout: .seconds(2)) {
            await loader.validatedURLs.count >= 1
        }
        let urls = await loader.validatedURLs
        #expect(urls.contains(url))
    }

    @Test("Validation failure does not promote the rejected bookmark to active config")
    func videoSelectionHandlesValidationFailure() async throws {
        guard let screen = Self.makeScreen() else {
            Issue.record("No NSScreen available for dependency injection test")
            return
        }
        let loader = FakePlayableVideoLoader(validationError: .validationFailed)
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: loader,
            displayRegistry: FakeDisplayRegistry(screens: [screen])
        ))
        guard let liveScreen = manager.screens.first else {
            Issue.record("Injected display registry did not produce a screen")
            return
        }

        let initialBookmark = Self.activeVideoBookmark(manager.getConfiguration(for: liveScreen))
        let rejectedBookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtocolizedDependencies-Failure-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("dummy data".utf8).write(to: url)

        manager.setVideo(url: url, bookmarkData: rejectedBookmark, for: liveScreen)

        try await Self.waitUntil(timeout: .seconds(2)) {
            await loader.validatedURLs.count >= 1
        }
        try await Task.sleep(for: .milliseconds(50))

        let finalBookmark = Self.activeVideoBookmark(manager.getConfiguration(for: liveScreen))
        #expect(finalBookmark != rejectedBookmark, "Rejected bookmark must not become active")
        #expect(finalBookmark == initialBookmark, "Active bookmark should be unchanged on validation failure")
    }

    @Test("Startup options equality preserves legacy boolean semantics")
    func startupOptionsEqualityIgnoresInjectedDependencyIdentity() {
        let lhs = ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry()
        )
        let rhs = ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(initialPowerSource: .battery(level: 0.1)),
            fullScreenDetector: FakeFullScreenDetector(hiddenScreens: [123: true]),
            playableVideoLoader: FakePlayableVideoLoader(validationError: .validationFailed),
            displayRegistry: FakeDisplayRegistry()
        )

        #expect(lhs == rhs)
    }

    private static func makeScreen() -> Screen? {
        NSScreen.screens.first.map(Screen.init(nsScreen:))
    }

    private static func activeVideoBookmark(_ configuration: ScreenConfiguration?) -> Data? {
        guard case .video(let bookmark) = configuration?.activeWallpaper else { return nil }
        return bookmark
    }

    private static func waitUntil(
        timeout: Duration,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for async condition")
    }
}
