import AppKit
import Foundation
import LiveWallpaperCore
import os
import SwiftUI
import Testing
@testable import LiveWallpaper

@Suite("Protocolized ScreenManager dependencies")
@MainActor
struct ProtocolizedDependenciesTests {

    @Test("Unconfigured ScreenManager construction stays featureless")
    func unconfiguredManagerFailsClosed() {
        let forged = ProductCapabilities(
            sku: .unconfigured,
            enabledFeatures: Set(ProductFeature.allCases)
        )
        let workshopAttempt = ProductCapabilities.unconfigured.withWorkshopOnline()
        let environmentCatalog = EnvironmentValues().featureCatalog
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))

        #expect(forged.enabledFeatures.isEmpty)
        #expect(workshopAttempt.enabledFeatures.isEmpty)
        #expect(environmentCatalog == .unconfigured)
        #expect(manager.featureCatalog.capabilities.sku == .unconfigured)
        #expect(ProductFeature.allCases.allSatisfy { !manager.featureCatalog.isEnabled($0) })
    }

    @Test("ScreenManager and SwiftUI environment have no implicit Pro catalog")
    func capabilityDefaultsFailClosedByContract() throws {
        let types = try RepositoryRoot.source("LiveWallpaper/App/ScreenManagerTypes.swift")
        let manager = try RepositoryRoot.source("LiveWallpaper/App/ScreenManager.swift")
        let capabilities = try RepositoryRoot.source(
            "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift"
        )

        #expect(types.contains("var featureCatalog: FeatureCatalog"))
        #expect(!types.contains("var featureCatalog: FeatureCatalog ="))
        #expect(manager.contains("init(startupOptions: ScreenManagerStartupOptions)"))
        #expect(!manager.contains("init(startupOptions: ScreenManagerStartupOptions ="))
        #expect(capabilities.contains("static let defaultValue = FeatureCatalog.unconfigured"))
        #expect(!capabilities.contains("static let defaultValue = FeatureCatalog(capabilities: .pro)"))
    }

    @Test("Termination is one-way and rejects queued screen rebuilds")
    func terminationRejectsLateScreenRefresh() {
        let displayRegistry = FakeDisplayRegistry()
        let fullScreenDetector = FakeFullScreenDetector()
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: fullScreenDetector,
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: displayRegistry,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        let readsBeforeTermination = displayRegistry.currentScreensCallCount
        #expect(!manager.effectsCoordinatorWasInitialized)

        manager.tearDownForTermination()
        manager.refreshScreens()
        manager.reconcileMonitorOverlays()
        manager.updateFullScreenFallbackPolling()
        manager.handleGlobalSettingsChanged()
        manager.startWeatherMonitoring()
        manager.tearDownForTermination()

        #expect(manager.isTerminating)
        #expect(displayRegistry.currentScreensCallCount == readsBeforeTermination)
        #expect(manager.screens.allSatisfy { $0.runtimeSession == nil })
        #expect(!MonitorOverlayController.shared.hasActiveOverlay)
        #expect(!manager.effectsCoordinatorWasInitialized, "Quit must not instantiate unused weather/effects services")
        #expect(fullScreenDetector.setFallbackPollingEnabledValues.last == false)
        #expect(fullScreenDetector.stopCallCount == 1)
    }

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
            displayRegistry: displayRegistry,
            featureCatalog: FeatureCatalog(capabilities: .pro)
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
            displayRegistry: displayRegistry,
            featureCatalog: FeatureCatalog(capabilities: .pro)
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
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
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
            displayRegistry: FakeDisplayRegistry(),
            featureCatalog: FeatureCatalog(capabilities: .pro)
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
            displayRegistry: displayRegistry,
            featureCatalog: FeatureCatalog(capabilities: .pro)
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
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
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

    @Test("Video facade rejects selections issued after termination")
    func videoFacadeRejectsSelectionAfterTermination() async throws {
        guard let screen = Self.makeScreen() else {
            Issue.record("No NSScreen available for termination video test")
            return
        }
        let loader = FakePlayableVideoLoader()
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: loader,
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        let liveScreen = try #require(manager.screens.first)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termination-facade-\(UUID().uuidString).mov")
        let configurationBeforeTermination = manager.getConfiguration(for: liveScreen)

        manager.tearDownForTermination()
        manager.setVideo(url: url, bookmarkData: Data([0xFA, 0xCE]), for: liveScreen)
        manager.setHTMLWallpaper(source: .inline("<p>late</p>"), for: liveScreen)
        manager.setShaderWallpaper(source: .builtin(.aurora), for: liveScreen)
        manager.applyBookmark(
            WallpaperBookmark(
                label: "Late bookmark",
                content: .html(source: .inline("<p>late bookmark</p>"), config: .default)
            ),
            to: liveScreen
        )
        await Task.yield()

        let validatedURLs = await loader.validatedURLs
        #expect(validatedURLs.isEmpty)
        #expect(liveScreen.runtimeSession == nil)
        #expect(manager.getConfiguration(for: liveScreen) == configurationBeforeTermination)
    }

    @Test("Delayed video validation cannot install or persist after lifecycle closes")
    func delayedVideoValidationCannotInstallAfterTermination() async throws {
        guard let screen = Self.makeScreen() else {
            Issue.record("No NSScreen available for delayed video termination test")
            return
        }
        let loader = FakePlayableVideoLoader(suspendsValidation: true)
        let persistence = RecordingConfigurationPersistence()
        let store = WallpaperConfigurationStore(persistence: persistence)
        let lifecycleChecks = LockedCounter()
        let notificationCount = LockedCounter()
        let lifecycleActive = OSAllocatedUnfairLock(initialState: true)
        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            playableVideoLoader: loader,
            applyPolicy: { _ in },
            applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 },
            screensProvider: { [screen] },
            markSessionStateChanged: {},
            releaseRuntimeSession: { $0.resetRuntimeSession() },
            notifyWallpaperSessionChanged: {},
            originReconciler: PreservingOriginReconciler(),
            isRuntimeInstallationAllowed: {
                lifecycleChecks.increment()
                return lifecycleActive.withLock { $0 }
            },
            notifyConfigurationChanged: { _ in notificationCount.increment() }
        )
        defer { _ = coordinator.transition.bumpTransition(for: screen.id) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termination-delayed-\(UUID().uuidString).mov")
        coordinator.setVideo(url: url, bookmarkData: Data([0xBE, 0xEF]), for: screen)
        try await Self.waitUntil(timeout: .seconds(2)) {
            await loader.pendingValidationCount == 1
        }

        lifecycleActive.withLock { $0 = false }
        await loader.resumeAllValidations()
        try await Self.waitUntil(timeout: .seconds(2)) {
            lifecycleChecks.value >= 2
        }

        #expect(screen.runtimeSession == nil)
        #expect(persistence.savedConfigurations.isEmpty)
        #expect(notificationCount.value == 0)
    }

    #if !LITE_BUILD
    @Test("System audio shutdown rejects every restart entry")
    func systemAudioShutdownIsOneWay() {
        let manager = SystemAudioCaptureManager()
        manager.shutdown()
        let stoppedState = manager.state

        manager.setEnabled(true)
        manager.retryAccessRequest()
        manager.retain()
        manager.release()

        #expect(manager.isTerminated)
        #expect(manager.state == stoppedState)
    }
    #endif

    @Test("Weather shutdown removes preference producer and rejects new work")
    func weatherShutdownIsOneWay() async {
        let locationProvider = RecordingWeatherLocationProvider()
        let service = WeatherReactiveService(locationProvider: locationProvider)

        service.shutdown()
        service.startMonitoring()
        service.refresh()
        service.requestLocationAuthorizationIfNeeded()
        await Task.yield()

        #expect(service.isShutdown)
        #expect(!service.hasActiveWork)
        #expect(!service.hasPreferenceObserver)
        #expect(locationProvider.authorizationRequestCount == 0)
        #expect(locationProvider.resolveCount == 0)
    }

    @Test("HUD shutdown preserves preference but rejects panel and pump recreation")
    func monitorHUDShutdownIsOneWay() {
        let persistedWrites = LockedCounter()
        let hud = MonitorHUDController(
            initiallyEnabled: false,
            persistEnabled: { _ in persistedWrites.increment() }
        )
        hud.shutdown()
        hud.isEnabled = true
        hud.show()

        #expect(hud.isShutdown)
        #expect(!hud.isPresented)
        #expect(!hud.hasActivePump)
        #expect(!hud.hasRuntimeLease)
        #expect(hud.isEnabled, "Shutdown must preserve the next-launch preference")
        #expect(persistedWrites.value == 1)
    }

    @Test("Startup options equality preserves legacy boolean semantics")
    func startupOptionsEqualityIgnoresInjectedDependencyIdentity() {
        let lhs = ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        )
        let rhs = ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(initialPowerSource: .battery(level: 0.1)),
            fullScreenDetector: FakeFullScreenDetector(hiddenScreens: [123: true]),
            playableVideoLoader: FakePlayableVideoLoader(validationError: .validationFailed),
            displayRegistry: FakeDisplayRegistry(),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        )

        #expect(lhs == rhs)
    }

    private static func makeScreen() -> Screen? {
        NSScreen.screens.first.map(Screen.init(nsScreen:))
    }

    private static func activeVideoBookmark(_ configuration: ScreenConfiguration?) -> Data? {
        guard case .video(let bookmark, _) = configuration?.activeWallpaper else { return nil }
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

@MainActor
private final class RecordingConfigurationPersistence: ScreenConfigurationPersisting {
    private var configurations: [CGDirectDisplayID: ScreenConfiguration] = [:]
    private(set) var savedConfigurations: [ScreenConfiguration] = []

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configurations[screenID]
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        configurations[configuration.screenID] = configuration
        savedConfigurations.append(configuration)
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        configurations[screenID] = nil
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        Array(configurations.values)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { ($0.screenID, $0) })
    }
}

@MainActor
private final class RecordingWeatherLocationProvider: WeatherLocationProviding {
    private(set) var authorizationRequestCount = 0
    private(set) var resolveCount = 0

    func resolveCoordinate() async -> WeatherLocationResolution {
        resolveCount += 1
        return .unresolved
    }

    func requestCoreLocationAuthorizationIfNeeded() {
        authorizationRequestCount += 1
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
