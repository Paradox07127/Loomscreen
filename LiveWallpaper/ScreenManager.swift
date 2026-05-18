import SwiftUI
import Combine
import Observation

struct WallpaperSessionSummaryCache: Equatable {
    private var summariesByScreenID: [CGDirectDisplayID: WallpaperSessionSummary] = [:]

    init() {}

    init(entries: [(CGDirectDisplayID, WallpaperSessionSummary)]) {
        replace(with: entries)
    }

    mutating func replace(with entries: [(CGDirectDisplayID, WallpaperSessionSummary)]) {
        summariesByScreenID = Dictionary(uniqueKeysWithValues: entries)
    }

    func summary(
        for screenID: CGDirectDisplayID,
        fallback: @autoclosure () -> WallpaperSessionSummary
    ) -> WallpaperSessionSummary {
        summariesByScreenID[screenID] ?? fallback()
    }
}

/// Equatable snapshot of the derived wallpaper-session state.
///
/// `markWallpaperSessionStateChanged()` and `notifyWallpaperSessionChanged()`
/// used to drive three independent observable mutations on `ScreenManager`
/// (version bump + summary-cache rebuild + Combine subject send), forcing
/// SwiftUI consumers to re-evaluate three times per session change. Folding
/// them into one `Equatable` struct lets us commit the new state in a single
/// observable assignment: views invalidate at most once, and the equality
/// guard skips the assignment entirely when nothing actually changed.
struct WallpaperSessionState: Equatable {
    var version: UInt64 = 0
    var summaryCache: WallpaperSessionSummaryCache = WallpaperSessionSummaryCache()
    var isAnyPlaying: Bool = false
}

struct ScreenManagerStartupOptions: Equatable {
    var restoreSavedWallpapers: Bool = true
    var startAutomation: Bool = true
    var powerMonitor: (any PowerMonitoring)? = nil
    var fullScreenDetector: (any FullScreenDetecting)? = nil
    var playableVideoLoader: (any PlayableVideoLoading)? = nil
    var displayRegistry: (any DisplayRegistering)? = nil
    /// SKU-driven feature toggles. The Lite app target injects
    /// `FeatureCatalog(capabilities: .lite)`; everything else defaults to
    /// the full Pro catalogue so legacy entry points keep current behaviour.
    var featureCatalog: FeatureCatalog = FeatureCatalog(capabilities: .pro)
    /// Strategy used to keep `ScreenConfiguration.wpeOrigin` in sync with
    /// the active wallpaper. Defaults to the full Pro behaviour so the
    /// monolithic app retains its current bookmark-matching semantics; Lite
    /// will swap in `PreservingOriginReconciler` once Phase 4 splits ProWPE.
    #if LITE_BUILD
    var originReconciler: any OriginReconciler = PreservingOriginReconciler()
    #else
    var originReconciler: any OriginReconciler = WPEOriginReconciler()
    #endif

    // Reference-typed protocol fields are not synthesizable for Equatable.
    // Compare only the value-typed boolean configuration; injected dependencies
    // are test-time concerns and equality is irrelevant for them.
    static func == (lhs: ScreenManagerStartupOptions, rhs: ScreenManagerStartupOptions) -> Bool {
        lhs.restoreSavedWallpapers == rhs.restoreSavedWallpapers
            && lhs.startAutomation == rhs.startAutomation
            && lhs.featureCatalog == rhs.featureCatalog
    }
}

@MainActor @Observable
final class ScreenManager {
    // MARK: - Properties

    private(set) var screens: [Screen] = []
    /// Single observable snapshot of derived wallpaper-session state. Every
    /// mutation flows through `commitWallpaperSessionState()`, which builds
    /// a new value, compares it against the current snapshot, and assigns
    /// only when the diff is real — at most one observation invalidation
    /// per session change.
    private(set) var wallpaperSessionState = WallpaperSessionState()
    /// Backwards-compatible view onto the snapshot's version counter. The
    /// underlying property is `wallpaperSessionState`, so reading this
    /// publisher still observes one canonical signal.
    var wallpaperSessionStateVersion: UInt64 { wallpaperSessionState.version }
    /// Backwards-compatible view onto the snapshot's summary cache.
    var wallpaperSessionSummaryCache: WallpaperSessionSummaryCache { wallpaperSessionState.summaryCache }
    #if !LITE_BUILD
    /// Per-screen WPE import bookkeeping (last error + generation counter).
    /// Held as an observed property so SwiftUI views reading
    /// `screenManager.wpeImportError(for:)` re-render when imports succeed
    /// or fail — the original `lastWPEImportErrors` dict was on this
    /// `@Observable` class, and we must preserve that invalidation flow.
    private let wpeImportTracker = WPEImportTracker()
    #endif
    /// Display-name cache for security-scoped bookmarks. Held as an observed
    /// property so views reading `screenManager.bookmarkDisplayName(for:)`
    /// re-render when entries land — see WPEImportTracker for the same
    /// pattern.
    private let bookmarkDisplayNameCache = BookmarkDisplayNameCache()

    @ObservationIgnored private var cleanupTasks: Set<AnyCancellable> = []
    @ObservationIgnored private let displayRegistry: any DisplayRegistering
    @ObservationIgnored let featureCatalog: FeatureCatalog
    @ObservationIgnored let originReconciler: any OriginReconciler
    @ObservationIgnored private let configurationStore = WallpaperConfigurationStore()
    @ObservationIgnored private let ambientSessionBuilder = AmbientWallpaperSessionBuilder()
    @ObservationIgnored private let automationCoordinator = WallpaperAutomationCoordinator()
    @ObservationIgnored private let powerPolicy = PowerPolicyController()
    @ObservationIgnored private let powerMonitor: any PowerMonitoring
    @ObservationIgnored private let playbackStateSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored private let fullScreenDetector: any FullScreenDetecting
    @ObservationIgnored private let playableVideoLoader: any PlayableVideoLoading
    @ObservationIgnored private let restoresSavedWallpapersOnScreenRefresh: Bool
    @ObservationIgnored private var transientRuntimeErrors: [CGDirectDisplayID: WallpaperRuntimeError] = [:]
    @ObservationIgnored private let exclusiveRenderingCoordinator = ExclusiveRenderingCoordinator()
    @ObservationIgnored private var exclusiveRenderingObservation: NSObjectProtocol?
    /// Coordinates per-screen playback configuration mutations + transition
    /// tokens. Lazy because it captures `self` for the effect-application and
    /// refresh-rate-lookup callbacks; the stored properties used by those
    /// callbacks (`videoEffectsApplier`, `refreshRateCache`, etc.) are already
    /// initialised by the time the lazy var is touched.
    @ObservationIgnored private lazy var playbackCoordinator = PlaybackCoordinator(
        configurationStore: configurationStore,
        powerMonitor: powerMonitor,
        fullScreenDetector: fullScreenDetector,
        powerPolicy: powerPolicy,
        playableVideoLoader: playableVideoLoader,
        applyVideoEffects: { [weak self] screen, config in
            self?.effectsCoordinator.applyVideoEffects(for: screen, config: config)
        },
        refreshRateLookup: { [weak self] screenID in
            self?.getScreenRefreshRate(for: screenID) ?? 60
        },
        screensProvider: { [weak self] in
            self?.screens ?? []
        },
        markSessionStateChanged: { [weak self] in
            self?.markWallpaperSessionStateChanged()
        },
        releaseRuntimeSession: { [weak self] screen in
            self?.releaseRuntimeSession(screen)
        },
        notifyWallpaperSessionChanged: { [weak self] in
            self?.notifyWallpaperSessionChanged()
        },
        reportRuntimeError: { [weak self] screenID, error in
            self?.setTransientRuntimeError(error, for: screenID)
        },
        originReconciler: originReconciler
    )
    /// Lazy because the `saveConfiguration` / `restoreWallpaperSession`
    /// callbacks capture `self` (matches `playbackCoordinator`'s pattern).
    #if !LITE_BUILD
    /// Shares the `wpeImportTracker` reference so both this coordinator and
    /// the view-facing `wpeImportError(for:)` reader observe the same state.
    @ObservationIgnored private lazy var wpeImportCoordinator = WPEImportCoordinator(
        tracker: wpeImportTracker,
        configurationStore: configurationStore,
        saveConfiguration: { [weak self] config in
            self?.saveConfiguration(config)
        },
        restoreWallpaperSession: { [weak self] screen, config, preservingState in
            self?.restoreWallpaperSession(for: screen, configuration: config, preservingState: preservingState)
        }
    )
    #endif
    /// Centralises the write side of ScreenConfiguration persistence (save /
    /// remove / prune / validate / display-name priming). Lazy because the
    /// `releaseRuntimeSession` callback resolves a `Screen` by ID via `self`.
    @ObservationIgnored private lazy var persistence = WallpaperPersistenceCoordinator(
        store: configurationStore,
        bookmarkDisplayNameCache: bookmarkDisplayNameCache,
        releaseRuntimeSession: { [weak self] screenID in
            guard let self,
                  let screen = self.screens.first(where: { $0.id == screenID }) else { return }
            Logger.warning("Removing invalid resource configuration for screen \(screenID)", category: .settings)
            self.releaseRuntimeSession(screen)
        },
        notifyWallpaperSessionChanged: { [weak self] in
            self?.notifyWallpaperSessionChanged()
        }
    )
    @ObservationIgnored private var transitionRegistry: PlaybackTransitionRegistry {
        playbackCoordinator.transition
    }
    /// Owns playlist + schedule automation, including the
    /// `WallpaperAutomationCoordinator.start(...)` wiring. Lazy because
    /// many of the callbacks (saveConfiguration, releaseRuntimeSession,
    /// setupVideoPlayback) capture self.
    @ObservationIgnored private lazy var automationOrchestrator = WallpaperAutomationOrchestrator(
        configurationStore: configurationStore,
        automationCoordinator: automationCoordinator,
        playableVideoLoader: playableVideoLoader,
        screensProvider: { [weak self] in
            self?.screens ?? []
        },
        saveConfiguration: { [weak self] config in
            self?.saveConfiguration(config)
        },
        recordBookmarkDisplayName: { [weak self] bookmark, name in
            self?.recordBookmarkDisplayName(bookmark, name: name)
        },
        releaseRuntimeSession: { [weak self] screen in
            self?.releaseRuntimeSession(screen)
        },
        setupVideoPlayback: { [weak self] url, screen in
            self?.setupVideoPlayback(url: url, screen: screen)
        },
        reloadWallpaperForScreen: { [weak self] screen in
            self?.reloadWallpaperForScreen(screen)
        },
        bumpTransition: { [weak self] screenID in
            self?.bumpTransition(for: screenID) ?? 0
        },
        isCurrentTransition: { [weak self] generation, screenID in
            self?.isCurrentTransition(generation, for: screenID) ?? false
        }
    )
    /// Owns HTML wallpaper management (setters + multi-instance audio-leader
    /// + trust evaluation). Lazy because the saveConfiguration /
    /// restoreWallpaperSession / notifyWallpaperSessionChanged callbacks
    /// capture self.
    @ObservationIgnored private lazy var htmlCoordinator = HTMLWallpaperCoordinator(
        configurationStore: configurationStore,
        screensProvider: { [weak self] in
            self?.screens ?? []
        },
        saveConfiguration: { [weak self] config in
            self?.saveConfiguration(config)
        },
        restoreWallpaperSession: { [weak self] screen, config, preservingState in
            self?.restoreWallpaperSession(for: screen, configuration: config, preservingState: preservingState)
        },
        notifyWallpaperSessionChanged: { [weak self] in
            self?.notifyWallpaperSessionChanged()
        },
        originReconciler: originReconciler
    )
    /// Owns the CIFilter video-effects pipeline + weather-reactive monitor.
    /// Lazy because the saveConfiguration / applyFrameRateLimit /
    /// screenRefreshRate / screensProvider callbacks capture self.
    @ObservationIgnored private lazy var effectsCoordinator = WallpaperEffectsCoordinator(
        configurationStore: configurationStore,
        screensProvider: { [weak self] in
            self?.screens ?? []
        },
        saveConfiguration: { [weak self] config in
            self?.saveConfiguration(config)
        },
        applyFrameRateLimit: { [weak self] limit, screen in
            self?.applyFrameRateLimit(limit, to: screen)
        },
        screenRefreshRate: { [weak self] screenID in
            self?.getScreenRefreshRate(for: screenID) ?? 60
        }
    )
    /// Exposed for the WeatherLocation settings view, which reads
    /// `currentParticleEffect` / `currentEffectAdjustments` directly and
    /// triggers `refresh()` on user gestures. The actual instance is owned
    /// by the effects coordinator.
    var weatherService: WeatherReactiveService { effectsCoordinator.weatherService }
    @ObservationIgnored private lazy var lockScreenSnapshotCoordinator = LockScreenSnapshotCoordinator { [weak self] in
        self?.captureDesktopSnapshotsForLockIfNeeded()
    }
    /// Bumped each time `scheduleConsoleKeyTracking()` registers a new
    /// observer. The onChange callback short-circuits when its captured
    /// generation no longer matches the latest value, so accidentally
    /// re-registering does not cascade into stacked callbacks.
    @ObservationIgnored private var consoleKeyTrackingGeneration: UInt64 = 0
    /// Same idempotency token as `consoleKeyTrackingGeneration`, applied to
    /// `observeFullScreenChanges()`.
    @ObservationIgnored private var fullScreenTrackingGeneration: UInt64 = 0
    // MARK: - Initialization
    init(startupOptions: ScreenManagerStartupOptions = ScreenManagerStartupOptions()) {
        displayRegistry = startupOptions.displayRegistry ?? DisplayRegistry()
        featureCatalog = startupOptions.featureCatalog
        originReconciler = startupOptions.originReconciler
        powerMonitor = startupOptions.powerMonitor ?? PowerMonitor.shared
        fullScreenDetector = startupOptions.fullScreenDetector ?? FullScreenDetector()
        playableVideoLoader = startupOptions.playableVideoLoader ?? PlayableVideoLoader()
        restoresSavedWallpapersOnScreenRefresh = startupOptions.restoreSavedWallpapers

        Logger.notice("ScreenManager initializing", category: .screenManager)
        setupPowerMonitoring()
        setupScreenObservers()
        if featureCatalog.isEnabled(.systemMonitor) {
            setupMemoryMonitoring()
        }
        setupFullScreenDetection()
        // Exclusive-rendering coordinator only matters when scene wallpapers
        // can run — Lite skips it entirely to avoid the foreground-watcher.
        if featureCatalog.isEnabled(.scene) {
            setupExclusiveRenderingCoordinator()
        }
        // Lock-screen capture pipeline is Pro-only.
        if featureCatalog.isEnabled(.lockScreenSnapshots) {
            _ = lockScreenSnapshotCoordinator
        }

        NotificationCenter.default.publisher(for: WallpaperVideoPlayer.didChangePlaybackStateNotification)
            .sink { [weak self] _ in
                self?.markWallpaperSessionStateChanged()
            }
            .store(in: &cleanupTasks)

        // refreshScreens() already calls loadConfigurationForScreen on every
        // newly registered screen (during init, every screen is "new"), so a
        // separate loadSavedConfigurations() pass is pure duplicate work and
        // was a contributor to the launch-time GPU spike.
        refreshScreens()
        if startupOptions.startAutomation {
            // Automation (playlist + schedule) and weather monitor are
            // independent Pro features; skip each only when its capability
            // is off so a future SKU can enable one without the other.
            if featureCatalog.isEnabled(.playlists) || featureCatalog.isEnabled(.scheduleAutomation) {
                automationOrchestrator.startMonitoring()
            }
            if featureCatalog.isEnabled(.weatherReactive) {
                startWeatherMonitoring()
            }
        }
        Logger.notice("ScreenManager initialization complete", category: .screenManager)
    }
    
    // MARK: - Observers Setup
    private func setupPowerMonitoring() {
        powerMonitor.powerSourcePublisher
            .sink { [weak self] powerSource in
                self?.handlePowerStateChange(powerSource)
            }
            .store(in: &cleanupTasks)
        
        let initialPowerSource = powerMonitor.currentPowerSource
        handlePowerStateChange(initialPowerSource)
    }
    
    private func setupScreenObservers() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .throttle(for: .seconds(1.0), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.handleScreenParameterChange()
            }
            .store(in: &cleanupTasks)
        
        // Sleep / wake notifications are posted on NSWorkspace's notification
        // center, NOT NotificationCenter.default. The previous version subscribed
        // on the wrong center and effectively never fired on wake.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                self?.handleSystemSleep()
            }
            .store(in: &cleanupTasks)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.handleSystemWake()
            }
            .store(in: &cleanupTasks)
    }
    
    private func handleScreenParameterChange() {
        refreshRateCache.removeAll()
        refreshScreens(preserveRuntimeSessions: true)

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.updateAllWindowFrames()
            try? await Task.sleep(for: .milliseconds(500))
            self?.updateAllWindowFrames()
        }


    }

    /// Updates all wallpaper window frames to match their screen positions.
    private func updateAllWindowFrames() {
        for screen in screens {
            if let nsScreen = displayRegistry.findNSScreen(for: screen.id) {
                screen.updateRuntimeFrame(to: nsScreen.frame)
            } else {
                Logger.warning("Could not find NSScreen for screen ID \(screen.id), using stored frame", category: .screenManager)
                screen.updateRuntimeFrame(to: screen.frame)
            }
        }
        playbackCoordinator.refreshVideoRendering()
    }
    
    private func setupMemoryMonitoring() {
        SystemMonitor.shared.startMonitoring()

        NotificationCenter.default.publisher(for: .systemMemoryWarning)
            .sink { [weak self] _ in
                self?.handleLowMemory()
            }
            .store(in: &cleanupTasks)
    }

    private func setupFullScreenDetection() {
        observeFullScreenChanges()
        fullScreenDetector.checkNow()
        handleFullScreenChange(fullScreenDetector.hiddenScreens)
    }

    /// Wires the console-key-window observer so scene wallpapers throttle to
    /// 1 fps while the user is interacting with the LiveWallpaper UI. This is
    /// the Phase 2.0 "exclusive rendering" policy — scene rendering is the
    /// most expensive wallpaper type and should yield to anything in the
    /// foreground.
    private func setupExclusiveRenderingCoordinator() {
        exclusiveRenderingCoordinator.start()
        // Observation framework: register a withObservationTracking loop so
        // the throttle propagates to every scene session.
        scheduleConsoleKeyTracking()
    }

    private func scheduleConsoleKeyTracking() {
        consoleKeyTrackingGeneration &+= 1
        let generation = consoleKeyTrackingGeneration
        let snapshot = exclusiveRenderingCoordinator.isConsoleKeyWindow
        applyConsoleKeyState(isConsoleKey: snapshot)
        withObservationTracking {
            _ = exclusiveRenderingCoordinator.isConsoleKeyWindow
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.consoleKeyTrackingGeneration == generation else { return }
                self.applyConsoleKeyState(isConsoleKey: self.exclusiveRenderingCoordinator.isConsoleKeyWindow)
                self.scheduleConsoleKeyTracking()
            }
        }
    }

    private func applyConsoleKeyState(isConsoleKey: Bool) {
        #if !LITE_BUILD
        for screen in screens {
            guard let session = screen.runtimeSession as? SceneWallpaperSession else { continue }
            session.setThrottled(isConsoleKey)
        }
        #endif
    }

    private func observeFullScreenChanges() {
        fullScreenTrackingGeneration &+= 1
        let generation = fullScreenTrackingGeneration
        withObservationTracking {
            _ = fullScreenDetector.hiddenScreens
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.fullScreenTrackingGeneration == generation else { return }
                self.handleFullScreenChange(self.fullScreenDetector.hiddenScreens)
                self.observeFullScreenChanges()
            }
        }
    }

    private func handleFullScreenChange(_ hiddenScreens: [CGDirectDisplayID: Bool]) {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()

        for screen in screens {
            let isHidden = hiddenScreens[screen.id] ?? false
            let shouldApplyFullScreenPolicy = WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
                globalSettings: globalSettings,
                isHiddenByFullScreen: isHidden
            )

            if shouldApplyFullScreenPolicy {
                if let playback = screen.playbackController, playback.isPlaying {
                    playback.pause()
                    powerPolicy.markPausedByFullScreen(screen.id)
                }
            } else {
                if let playback = screen.playbackController,
                   powerPolicy.wasPausedByFullScreen(screen.id) {
                    if WallpaperPolicyEngine.shouldResumeFromFullScreen(
                        globalSettings: globalSettings,
                        powerSource: powerMonitor.currentPowerSource,
                        wasPausedByFullScreen: true
                    ) {
                        playback.play()
                    }
                    powerPolicy.markResumedFromFullScreen(screen.id)
                }
            }

            applyPerformancePolicy(
                to: screen,
                globalSettings: globalSettings,
                powerSource: powerMonitor.currentPowerSource,
                isHiddenByFullScreen: shouldApplyFullScreenPolicy
            )
        }
        updatePlaybackState()
    }

    // MARK: - Screen Management
    func refreshScreens(preserveRuntimeSessions: Bool = true) {
        let newScreens = displayRegistry.currentScreens()
        Logger.screensDetected(newScreens.count)

        let oldScreens = screens
        let oldScreenIDs = Set(oldScreens.map(\.id))
        let newScreenIDs = Set(newScreens.map(\.id))

        for screenID in oldScreenIDs.subtracting(newScreenIDs) {
            if let screen = oldScreens.first(where: { $0.id == screenID }) {
                Logger.info("Cleaning up removed screen \(screenID)", category: .screenManager)
                releaseRuntimeSession(screen)
            }
            
        }

        if !preserveRuntimeSessions {
            for screen in oldScreens where newScreenIDs.contains(screen.id) {
                releaseRuntimeSession(screen)
            }
        }
        
        var updatedScreens = [Screen]()

        for newScreen in newScreens {
            if preserveRuntimeSessions, let existingScreen = oldScreens.first(where: { $0.id == newScreen.id }) {
                newScreen.adoptRuntimeSession(from: existingScreen)
            }

            updatedScreens.append(newScreen)
        }

        screens = updatedScreens

        for screen in newScreens where newScreenIDs.subtracting(oldScreenIDs).contains(screen.id) {
            Logger.info("Configuring new screen \(screen.id)", category: .screenManager)
            if restoresSavedWallpapersOnScreenRefresh {
                loadConfigurationForScreen(screen)
            }
        }

        updateAllWindowFrames()

        refreshWallpaperSessionSummaryCache()
        updatePlaybackState()
        updateFullScreenFallbackPolling()

        NotificationCenter.default.post(name: .screensRefreshed, object: nil)
    }

    func clearWallpaperForScreen(_ screen: Screen) {
        Logger.info("Clearing wallpaper for screen \(screen.id)", category: .screenManager)
        releaseRuntimeSession(screen)
        persistence.remove(for: screen.id)
        notifyWallpaperSessionChanged()
    }

    /// Tears down the live runtime session for a screen without touching persistence.
    /// Use `clearWallpaperForScreen(_:)` when you also want to delete the saved
    /// configuration for that screen.
    private func releaseRuntimeSession(_ screen: Screen) {
        // Bump generation first so any in-flight async transition (e.g.
        // setVideo / playlist / schedule) sees the new value and short-circuits
        // before instantiating a player against a now-dead screen.
        bumpTransition(for: screen.id)
        effectsCoordinator.cancelInflight(for: screen.id)
        transitionRegistry.cancelAssetReadiness(for: screen.id)
        setTransientRuntimeError(nil, for: screen.id)
        screen.resetRuntimeSession()
        playbackCoordinator.refreshVideoAudioLeadership()
        powerPolicy.clearTracking(for: screen.id)
    }

    func resetAllWallpaperSessions() {
        let snapshot = screens
        for screen in snapshot {
            releaseRuntimeSession(screen)
        }
        configurationStore.clearCache()
        // Broadcast per-screen so ScreenDetailView re-reads its now-empty
        // configuration and drops the @State copies it held for the
        // previous wallpaper (preview source, mode picker, effect config,
        // playlist / schedule rows, etc.). Without this the inspector
        // continues to show the pre-reset video info even after the
        // runtime session is gone.
        Task { @MainActor in
            for screen in snapshot {
                NotificationCenter.default.post(
                    name: .wallpaperConfigurationDidChange,
                    object: nil,
                    userInfo: ["screenID": screen.id]
                )
            }
        }
        notifyWallpaperSessionChanged()
    }
    
    // MARK: - Configuration Management

    /// Light launch-time pass: prunes configurations whose local resource
    /// bookmark is no longer resolvable. Does not tear down healthy sessions.
    func pruneInvalidConfigurationsIfNeeded() {
        persistence.pruneInvalidConfigurations()
    }

    private func loadConfigurationForScreen(_ screen: Screen) {
        // If screen already has a video player, just update settings
        if screen.videoPlayer != nil {
            if let cachedConfig = configurationStore.get(for: screen.id) {
                primeBookmarkDisplayNames(from: cachedConfig)
                // Apply configuration without recreating the player
                applyConfiguration(cachedConfig, to: screen, preservingState: true)
            }
            return
        }

        guard let config = configurationStore.get(for: screen.id) else { return }
        primeBookmarkDisplayNames(from: config)
        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
    }

    private func restoreWallpaperSession(
        for screen: Screen,
        configuration: ScreenConfiguration,
        preservingState: Bool
    ) {
        guard let definition = WallpaperSessionDefinition(configuration: configuration) else {
            Logger.warning("Skipping malformed wallpaper configuration for screen \(screen.id)", category: .screenManager)
            releaseRuntimeSession(screen)
            return
        }

        switch definition {
        case .video:
            applyConfiguration(configuration, to: screen, preservingState: preservingState)
        case .html(let source, let htmlConfig):
            activateAmbientWallpaper(.html(source, htmlConfig), for: screen, configuration: configuration)
        case .metalShader(let preset):
            activateAmbientWallpaper(.metalShader(preset), for: screen, configuration: configuration)
        case .scene(let descriptor):
            activateAmbientWallpaper(.scene(descriptor), for: screen, configuration: configuration)
        }
    }
    
    // MARK: - Video Management

    /// Replaces the primary video while preserving per-screen settings.
    func setVideo(url: URL, bookmarkData: Data, for screen: Screen) {
        recordBookmarkDisplayName(bookmarkData, name: url.lastPathComponent)
        playbackCoordinator.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
    }

    @discardableResult
    private func bumpTransition(for screenID: CGDirectDisplayID) -> Int {
        transitionRegistry.bumpTransition(for: screenID)
    }

    private func isCurrentTransition(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool {
        transitionRegistry.isCurrentTransition(generation, for: screenID)
    }

    private func applyConfiguration(_ configuration: ScreenConfiguration, to screen: Screen, preservingState: Bool = false) {
        playbackCoordinator.applyConfiguration(configuration, to: screen, preservingState: preservingState)
    }

    private func setupVideoPlayback(url: URL, screen: Screen) {
        playbackCoordinator.setupVideoPlayback(url: url, screen: screen)
    }

    // MARK: - Icon Management
    var playbackStatePublisher: AnyPublisher<Bool, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }
    
    var isAnyScreenPlaying: Bool {
        playbackStateSubject.value
    }

    var wallpaperSessionSummaries: [WallpaperSessionSummary] {
        screens.map { wallpaperSummary(for: $0) }
    }

    var wallpaperOverviewStatus: WallpaperOverviewStatus {
        WallpaperStatusAggregator.overview(for: wallpaperSessionSummaries)
    }

    var hasControllableWallpaperSessions: Bool {
        wallpaperSessionSummaries.contains { $0.isConfigured && $0.supportsPlaybackControl }
    }

    func wallpaperSummary(for screen: Screen) -> WallpaperSessionSummary {
        wallpaperSessionSummaryCache.summary(for: screen.id, fallback: screen.wallpaperSessionSummary)
    }

    /// Currently surfaced error for a screen's runtime session (or `nil`).
    /// Reads through `wallpaperSessionStateVersion` so SwiftUI re-evaluates
    /// the banner when the session reports a new state.
    func runtimeError(for screen: Screen) -> WallpaperRuntimeError? {
        _ = wallpaperSessionStateVersion
        return transientRuntimeErrors[screen.id] ?? screen.runtimeSession?.runtimeError
    }

    private func setTransientRuntimeError(_ error: WallpaperRuntimeError?, for screenID: CGDirectDisplayID) {
        let didChange: Bool
        if let error {
            didChange = transientRuntimeErrors[screenID] != error
            transientRuntimeErrors[screenID] = error
        } else {
            didChange = transientRuntimeErrors.removeValue(forKey: screenID) != nil
        }
        guard didChange else { return }

        var next = wallpaperSessionState
        next.version &+= 1
        wallpaperSessionState = next
    }

    func retryRuntimeSession(for screen: Screen) {
        Task { @MainActor [weak self, weak screen] in
            guard let self, let screen else { return }
            await screen.runtimeSession?.retry()
            self.markWallpaperSessionStateChanged()
        }
    }

    /// Subscribes the manager to a session's error changes so the SwiftUI
    /// banner refreshes when a player or web view starts / clears a failure.
    private func observeRuntimeErrors(for session: any WallpaperRuntimeSession) {
        let notify: @MainActor () -> Void = { [weak self] in
            self?.markWallpaperSessionStateChanged()
        }
        if let session = session as? VideoWallpaperSession {
            session.onRuntimeErrorChange = notify
        } else if let session = session as? AmbientWallpaperSession {
            session.onRuntimeErrorChange = notify
        }
    }

    func wallpaperDisplayName(for screen: Screen) -> String? {
        guard let configuration = configurationStore.get(for: screen.id),
              let definition = WallpaperSessionDefinition(configuration: configuration) else { return nil }

        return definition.displayName(using: { bookmarkDisplayName(for: $0) })
    }

    func bookmarkDisplayName(for bookmarkData: Data) -> String? {
        bookmarkDisplayNameCache.name(for: bookmarkData)
    }

    func currentVideoDisplayName(for screen: Screen) -> String? {
        guard let config = configurationStore.get(for: screen.id) else { return nil }
        let cursor = config.playlistCursorIndex ?? 0
        let combined = [config.savedVideoBookmarkData].compactMap { $0 } + (config.playlistBookmarks ?? [])
        guard cursor < combined.count else {
            return config.savedVideoBookmarkData.flatMap { bookmarkDisplayName(for: $0) }
        }
        return bookmarkDisplayName(for: combined[cursor])
    }

    func recordBookmarkDisplayName(_ bookmarkData: Data, name: String?) {
        bookmarkDisplayNameCache.record(bookmarkData, name: name)
    }

    private func primeBookmarkDisplayNames(from configuration: ScreenConfiguration) {
        persistence.primeDisplayNames(from: configuration)
    }

    /// Builds the next session-state snapshot from current screen state and
    /// commits it iff something actually changed. The version counter is
    /// incremented only on a real diff so consumers reading
    /// `wallpaperSessionStateVersion` to force a re-evaluation pulse stop
    /// receiving phantom pulses on no-op calls. Side-effects (Combine
    /// subject forwarding, full-screen polling) likewise run only on a real
    /// diff, except `includePollingRefresh` callers that need the polling
    /// step regardless (screen-set changes update fallback policy even when
    /// the playback derivative didn't move).
    private func commitWallpaperSessionState(includePollingRefresh: Bool = false) {
        var next = wallpaperSessionState
        next.summaryCache = WallpaperSessionSummaryCache(
            entries: screens.map { ($0.id, $0.wallpaperSessionSummary) }
        )
        next.isAnyPlaying = screens.contains { $0.playbackController?.isPlaying ?? false }

        let derivedChanged = next.summaryCache != wallpaperSessionState.summaryCache
            || next.isAnyPlaying != wallpaperSessionState.isAnyPlaying
        if derivedChanged {
            next.version &+= 1
            wallpaperSessionState = next
            if playbackStateSubject.value != next.isAnyPlaying {
                playbackStateSubject.send(next.isAnyPlaying)
            }
        }

        if includePollingRefresh {
            updateFullScreenFallbackPolling()
        }
    }

    private func markWallpaperSessionStateChanged() {
        commitWallpaperSessionState()
    }

    private func notifyWallpaperSessionChanged() {
        commitWallpaperSessionState(includePollingRefresh: true)
    }

    private func updatePlaybackState() {
        commitWallpaperSessionState()
    }

    private func refreshWallpaperSessionSummaryCache() {
        commitWallpaperSessionState()
    }

    func togglePlayback() {
        guard hasControllableWallpaperSessions else { return }

        let isAnyPlaying = screens.contains { $0.playbackController?.isPlaying ?? false }

        Logger.info("Toggling global playback: \(isAnyPlaying ? "pausing" : "playing") all videos", category: .videoPlayer)

        for screen in screens {
            guard let playback = screen.playbackController else { continue }

            if isAnyPlaying {
                powerPolicy.markResumedFromPower(screen.id)
                playback.pause()
            } else {
                playback.play()
            }
        }

        updatePlaybackState()
    }

    func setWallpapersEnabled(_ enabled: Bool) {
        guard !screens.isEmpty else { return }

        Logger.info("\(enabled ? "Enabling" : "Disabling") all wallpaper sessions from menu bar", category: .screenManager)

        for screen in screens {
            guard let session = screen.runtimeSession else { continue }

            if enabled {
                session.show()
                if let playback = screen.playbackController {
                    playback.play()
                } else {
                    session.resume()
                }
            } else {
                screen.playbackController?.pause()
                session.hide()
            }
        }

        markWallpaperSessionStateChanged()
    }
    
    // MARK: - Power Management
    private func handlePowerStateChange(_ powerSource: PowerMonitor.PowerSource) {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()

        var updatedScreens = false

        for screen in screens {
            let isHiddenByFullScreen = globalSettings.pauseOnFullScreen &&
                fullScreenDetector.isDesktopHidden(for: screen.id)

            applyPerformancePolicy(
                to: screen,
                globalSettings: globalSettings,
                powerSource: powerSource,
                isHiddenByFullScreen: isHiddenByFullScreen
            )

            let shouldPauseForPower = WallpaperPolicyEngine.shouldPauseForPower(
                globalSettings: globalSettings,
                powerSource: powerSource
            )
            let shouldResumeForPower = WallpaperPolicyEngine.shouldResumeFromPower(
                powerSource: powerSource,
                wasPausedByPower: powerPolicy.wasPausedByPower(screen.id)
            )

            if let playback = screen.playbackController {
                if shouldPauseForPower && playback.isPlaying {
                    Logger.debug("Pausing screen \(screen.id) due to power policy", category: .powerMonitor)
                    playback.pause()
                    powerPolicy.markPausedByPower(screen.id)
                    updatedScreens = true
                } else if shouldResumeForPower, !playback.isPlaying {
                    Logger.debug("Resuming screen \(screen.id) due to external power (was paused by power management)", category: .powerMonitor)
                    playback.play()
                    powerPolicy.markResumedFromPower(screen.id)
                    updatedScreens = true
                }
            } else if let runtimeSession = screen.runtimeSession {
                if shouldPauseForPower, !powerPolicy.wasPausedByPower(screen.id) {
                    Logger.debug("Suspending ambient session for screen \(screen.id) due to power policy", category: .powerMonitor)
                    runtimeSession.applyPerformanceProfile(.suspended)
                    powerPolicy.markPausedByPower(screen.id)
                } else if shouldResumeForPower {
                    Logger.debug("Resuming ambient session for screen \(screen.id) due to external power", category: .powerMonitor)
                    runtimeSession.applyPerformanceProfile(.quality)
                    powerPolicy.markResumedFromPower(screen.id)
                }
            }
        }

        if !powerSource.isOnBattery {
            let currentScreenIDs = Set(screens.map(\.id))
            powerPolicy.cleanUpStaleEntries(currentScreenIDs: currentScreenIDs)
        }

        if updatedScreens {
            updatePlaybackState()
        }
    }

    private func applyPerformancePolicy(
        to screen: Screen,
        globalSettings: GlobalSettings,
        powerSource: PowerMonitor.PowerSource,
        isHiddenByFullScreen: Bool
    ) {
        let profile = WallpaperPolicyEngine.performanceProfile(
            globalSettings: globalSettings,
            powerSource: powerSource,
            isHiddenByFullScreen: isHiddenByFullScreen
        )
        screen.runtimeSession?.applyPerformanceProfile(profile)
    }

    private func updateFullScreenFallbackPolling() {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let hasConfiguredSessions = wallpaperSessionSummaries.contains { $0.isConfigured }
        let shouldEnablePolling = WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: globalSettings,
            hasConfiguredWallpaperSessions: hasConfiguredSessions
        )

        fullScreenDetector.setFallbackPollingEnabled(shouldEnablePolling)
    }

    func handleGlobalSettingsChanged() {
        updateFullScreenFallbackPolling()
        handleFullScreenChange(fullScreenDetector.hiddenScreens)
        handlePowerStateChange(powerMonitor.currentPowerSource)
    }
    
    // MARK: - Memory Management
    private func handleLowMemory() {
        Logger.warning("Low memory condition detected, optimizing resource usage", category: .memory)

        for screen in screens {
            if let player = screen.videoPlayer, player.isPlaying {
                let isActive = NSScreen.screens.contains { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == screen.id }

                if !isActive {
                    Logger.debug("Pausing background video on screen \(screen.id) to conserve memory", category: .memory)
                    player.pause()
                }
            }
        }

    }
    
    // MARK: - System Events
    private func handleSystemSleep() {
        Logger.info("System sleep detected", category: .lifecycle)
        for screen in screens {
            screen.runtimeSession?.suspend()
        }
        markWallpaperSessionStateChanged()
    }

    private func handleSystemWake() {
        Logger.info("System wake detected", category: .lifecycle)
        for screen in screens {
            screen.runtimeSession?.resume()
        }
        refreshScreens()
        powerMonitor.refreshPowerStatus()
        handlePowerStateChange(powerMonitor.currentPowerSource)
    }

    private func captureDesktopSnapshotsForLockIfNeeded() {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        guard globalSettings.preservePlaybackOnLock else { return }

        for screen in screens {
            guard let config = configurationStore.get(for: screen.id),
                  config.wallpaperType == .video,
                  config.setAsLockScreen else { continue }
            extractLockScreenFrame(for: screen)
        }
    }
    
    // MARK: - Public Interface
    func reloadWallpaperForScreen(_ screen: Screen) {
        Logger.info("Manually reloading wallpaper for screen \(screen.id)", category: .screenManager)

        guard let configuration = configurationStore.get(for: screen.id) else {
            releaseRuntimeSession(screen)
            return
        }

        primeBookmarkDisplayNames(from: configuration)
        releaseRuntimeSession(screen)
        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }
    
    #if !LITE_BUILD
    // MARK: - Wallpaper Engine Import

    /// Returns the most recent WPE import error for the given screen, or `nil`.
    /// Used by the Scene tab to surface failures without bleeding state across
    /// concurrent imports on different displays.
    func wpeImportError(for screen: Screen) -> AppError? {
        wpeImportTracker.error(for: screen.id)
    }

    func clearWPEImportError(for screen: Screen) {
        wpeImportTracker.clearError(for: screen.id)
    }

    typealias WPEProjectPreparationOutcome = WPEImportCoordinator.PreparationOutcome
    typealias WPEProjectApplyOutcome = WPEImportCoordinator.ApplyOutcome

    func prepareWallpaperEngineProject(at folderURL: URL) async -> WPEProjectPreparationOutcome {
        await wpeImportCoordinator.prepareProject(at: folderURL)
    }

    @discardableResult
    func importWallpaperEngineProject(at folderURL: URL, for screen: Screen) async -> WPEProjectApplyOutcome {
        await wpeImportCoordinator.importProject(at: folderURL, for: screen)
    }

    func activateWPEHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async {
        await wpeImportCoordinator.activateHistoryEntry(entry, for: screen)
    }

    func removeWPEImport(workshopID: String) {
        wpeImportCoordinator.removeWorkshop(workshopID: workshopID)
    }
    #endif

    // MARK: - Configuration Update Helpers

    private func saveConfiguration(_ configuration: ScreenConfiguration) {
        persistence.save(configuration)
    }

    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        playbackCoordinator.updatePlaybackSpeed(speed, for: screen)
    }

    func updateMuted(_ muted: Bool, for screen: Screen) {
        playbackCoordinator.updateMuted(muted, for: screen)
    }

    func updateVideoVolume(_ volume: Double, for screen: Screen) {
        playbackCoordinator.updateVideoVolume(volume, for: screen)
    }

    func updateVideoDisplayMode(_ mode: VideoDisplayMode, for screen: Screen) {
        guard var sourceConfiguration = configurationStore.get(for: screen.id),
              sourceConfiguration.wallpaperType == .video,
              sourceConfiguration.hasConfiguredVideoSource else { return }

        switch mode {
        case .perDisplay:
            let sourceBookmark = sourceConfiguration.videoBookmarkData
            var changed = false

            for target in screens {
                guard var targetConfiguration = configurationStore.get(for: target.id),
                      targetConfiguration.wallpaperType == .video,
                      targetConfiguration.videoDisplayMode == .spanAllDisplays else { continue }

                if let sourceBookmark,
                   targetConfiguration.videoBookmarkData != sourceBookmark {
                    continue
                }

                targetConfiguration.videoDisplayMode = .perDisplay
                saveConfiguration(targetConfiguration)
                restoreWallpaperSession(for: target, configuration: targetConfiguration, preservingState: true)
                changed = true
            }

            if changed {
                notifyWallpaperSessionChanged()
            } else {
                playbackCoordinator.updateVideoDisplayMode(mode, for: screen)
            }

        case .spanAllDisplays:
            guard screens.count > 1 else {
                playbackCoordinator.updateVideoDisplayMode(.perDisplay, for: screen)
                return
            }

            sourceConfiguration.videoDisplayMode = .spanAllDisplays
            for target in screens {
                var copy = sourceConfiguration
                copy.screenID = target.id

                if target.id != screen.id {
                    releaseRuntimeSession(target)
                }

                saveConfiguration(copy)
                restoreWallpaperSession(
                    for: target,
                    configuration: copy,
                    preservingState: target.id == screen.id
                )
                Logger.info("Span Video: copied configuration from screen \(screen.id) → \(target.id)", category: .screenManager)
            }
            notifyWallpaperSessionChanged()
        }
    }

    func updateFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        playbackCoordinator.updateFitMode(fitMode, for: screen)
    }

    func updateFrameRateLimit(_ frameRateLimit: FrameRateLimit, for screen: Screen) {
        playbackCoordinator.updateFrameRateLimit(frameRateLimit, for: screen)
    }

    private func applyFrameRateLimit(_ frameRateLimit: FrameRateLimit, to screen: Screen) {
        playbackCoordinator.applyFrameRateLimit(frameRateLimit, to: screen)
    }
    
    func getConfiguration(for screen: Screen) -> ScreenConfiguration? {
        configurationStore.get(for: screen.id)
    }

    /// Copies the active wallpaper + per-screen settings from `source` onto
    /// every other registered screen, restoring each runtime session so the
    /// new content shows immediately. Used by the "Apply to All" toolbar
    /// action; no-op when there's only one screen.
    ///
    /// The target's existing runtime session is torn down BEFORE
    /// `restoreWallpaperSession`, otherwise the video path's reuse-existing-
    /// player branch would persist the new config but keep playing the old
    /// URL. `releaseRuntimeSession` also bumps the per-screen transition
    /// generation, so any in-flight async video load on the target invalidates
    /// itself instead of overwriting the apply-to-all result.
    func applyConfigurationToAllDisplays(from source: Screen) {
        guard screens.count > 1,
              let template = configurationStore.get(for: source.id) else { return }

        for target in screens where target.id != source.id {
            var copy = template
            copy.screenID = target.id
            releaseRuntimeSession(target)
            saveConfiguration(copy)
            restoreWallpaperSession(for: target, configuration: copy, preservingState: false)
            Logger.info("Apply to All: copied configuration from screen \(source.id) → \(target.id)", category: .screenManager)
        }
        notifyWallpaperSessionChanged()
    }
    
    func validateAllConfigurations() -> (valid: Int, invalid: Int) {
        persistence.validateAll()
    }
    
    /// Rebuilds display registry and runtime sessions from persisted config.
    func hardRefresh() {
        Logger.notice("Hard refresh: rebuilding display registry + runtime sessions", category: .screenManager)
        refreshRateCache.removeAll()
        refreshScreens(preserveRuntimeSessions: false)
        reloadAllScreens()
    }

    func reloadAllScreens() {
        Logger.notice("Reloading all screens", category: .screenManager)

        let removedScreenIDs = configurationStore.pruneInvalidResourceConfigurations(
            using: SettingsManager.shared.validateConfiguration
        )

        for removedScreenID in removedScreenIDs {
            if let screen = screens.first(where: { $0.id == removedScreenID }) {
                Logger.warning("Removing invalid video configuration for screen \(removedScreenID)", category: .settings)
                releaseRuntimeSession(screen)
            }
        }

        let configurations = configurationStore.loadAll()
        configurations.forEach { primeBookmarkDisplayNames(from: $0) }

        for screen in screens {
            guard let configuration = configurationStore.get(for: screen.id) else {
                releaseRuntimeSession(screen)
                continue
            }

            releaseRuntimeSession(screen)
            restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
        }

        Logger.notice("All screens reloaded", category: .screenManager)
    }
    
    // MARK: - Desktop Picture from Frame

    func updateSetAsDesktopPicture(_ enabled: Bool, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id),
              config.setAsLockScreen != enabled else { return }
        config.setAsLockScreen = enabled
        saveConfiguration(config)
    }

    func extractLockScreenFrame(for screen: Screen) {
        guard let player = screen.videoPlayer?.player else { return }

        DesktopPictureFrameExtractor.applyCurrentFrame(
            from: player,
            screenID: screen.id,
            nsScreen: displayRegistry.findNSScreen(for: screen.id)
        )
    }

    // MARK: - Video Effects / Weather-Reactive (delegates to coordinator)

    func updateEffectConfig(_ effectConfig: VideoEffectConfig, for screen: Screen) {
        effectsCoordinator.updateEffectConfig(effectConfig, for: screen)
    }

    func updateParticleEffect(_ effect: ParticleEffect, for screen: Screen) {
        effectsCoordinator.updateParticleEffect(effect, for: screen)
    }

    func updateParticleDensity(_ density: Double, for screen: Screen) {
        effectsCoordinator.updateParticleDensity(density, for: screen)
    }

    func setWeatherReactive(_ enabled: Bool, for screen: Screen) {
        effectsCoordinator.setWeatherReactive(enabled, for: screen)
    }

    func applyWeatherEffects(for screen: Screen) {
        effectsCoordinator.applyWeatherEffects(for: screen)
    }

    func startWeatherMonitoring() {
        effectsCoordinator.startWeatherMonitoring()
    }

    // MARK: - Wallpaper Type Switching

    func switchToVideoWallpaper(for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        let previousWallpaper = config.activeWallpaper
        guard config.activateSavedVideoWallpaper() else { return }

        // No-op switch: discard the local mutation (incl. playlistCursorIndex reset)
        // since nothing actually changed; persistence + session rebuild are skipped.
        if previousWallpaper == config.activeWallpaper,
           screen.runtimeSession?.wallpaperType == .video {
            Logger.info("Video wallpaper already active for screen \(screen.id); keeping existing player session", category: .screenManager)
            return
        }

        saveConfiguration(config)

        loadConfigurationForScreen(screen)
    }

    /// Restore previously-applied HTML source after the user toggles the type
    /// picker back to HTML. No-op if no HTML was ever set on this screen.
    func switchToHTMLWallpaper(for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        let previousWallpaper = config.activeWallpaper
        guard config.activateSavedHTMLWallpaper() else { return }

        if previousWallpaper == config.activeWallpaper,
           screen.runtimeSession?.wallpaperType == .html {
            Logger.info("HTML wallpaper already active for screen \(screen.id); keeping existing WKWebView session", category: .screenManager)
            return
        }

        saveConfiguration(config)
        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
    }

    func setSceneWallpaper(descriptor: SceneDescriptor, origin: WPEOrigin?, for screen: Screen) {
        var configuration = configurationStore.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .scene(descriptor)
        )
        if configuration.activeWallpaper == .scene(descriptor),
           configuration.wpeOrigin == origin,
           screen.runtimeSession?.wallpaperType == .scene {
            Logger.info("Scene wallpaper already active for screen \(screen.id); keeping existing scene session", category: .screenManager)
            return
        }

        configuration.activeWallpaper = .scene(descriptor)
        configuration.wpeOrigin = origin
        saveConfiguration(configuration)
        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }

    private func activateAmbientWallpaper(
        _ definition: WallpaperSessionDefinition,
        for screen: Screen,
        configuration: ScreenConfiguration
    ) {
        releaseRuntimeSession(screen)

        let session: AmbientWallpaperSession

        switch definition {
        case .html(let source, let htmlConfig):
            // Audio-leader policy: same source on multiple screens means N
            // independent webviews would each decode audio + render WebGL.
            // Force-mute all but the leader to avoid stacked audio. The
            // visual remains identical so users still get N×GPU — they're
            // warned via the Inspector banner.
            let isLeader = htmlCoordinator.isAudioLeader(source: source, excluding: screen.id)
            let effectiveConfig = htmlCoordinator.runtimeConfig(source: source, config: htmlConfig, for: screen)
            session = ambientSessionBuilder.makeHTMLSession(source: source, config: effectiveConfig, frame: screen.frame)
            Logger.info("Set HTML wallpaper for screen \(screen.id) — \(source.displayName) [leader=\(isLeader)]", category: .screenManager)
        case .metalShader(let preset):
            session = ambientSessionBuilder.makeShaderSession(preset: preset, frame: screen.frame)
            Logger.info("Set shader wallpaper (\(preset.rawValue)) for screen \(screen.id)", category: .screenManager)
        case .scene(let descriptor):
            #if !LITE_BUILD
            let dependencyMounts = WPEDependencyMountResolver().mounts(
                dependencyWorkshopIDs: descriptor.dependencyWorkshopIDs,
                origin: configuration.wpeOrigin
            )
            // Resolve the engine assets root at the call site so the runtime
            // never reaches back into the UI singleton; the renderer owns
            // the security scope for its lifetime.
            let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
            guard let sceneSession = ambientSessionBuilder.makeSceneSession(
                descriptor: descriptor,
                frame: screen.frame,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: engineRoot
            ) else {
                Logger.warning("Scene wallpaper for screen \(screen.id) (workshop \(descriptor.workshopID)) could not be built — cache missing or descriptor invalid", category: .screenManager)
                return
            }
            observeRuntimeErrors(for: sceneSession)
            screen.installRuntimeSession(sceneSession)
            // Sync exclusive-rendering state on install so a scene mounted
            // while the inspector window is already key starts at 1 fps
            // instead of waiting for the next focus toggle to throttle it.
            sceneSession.setThrottled(exclusiveRenderingCoordinator.isConsoleKeyWindow)
            let globalSettings = SettingsManager.shared.loadGlobalSettings()
            applyPerformancePolicy(
                to: screen,
                globalSettings: globalSettings,
                powerSource: powerMonitor.currentPowerSource,
                isHiddenByFullScreen: globalSettings.pauseOnFullScreen &&
                    fullScreenDetector.isDesktopHidden(for: screen.id)
            )
            Logger.info("Set scene wallpaper (workshop \(descriptor.workshopID)) for screen \(screen.id)", category: .screenManager)
            notifyWallpaperSessionChanged()
            #else
            _ = descriptor
            #endif
            return
        case .video:
            return
        }

        observeRuntimeErrors(for: session)
        screen.installRuntimeSession(session)
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        applyPerformancePolicy(
            to: screen,
            globalSettings: globalSettings,
            powerSource: powerMonitor.currentPowerSource,
            isHiddenByFullScreen: globalSettings.pauseOnFullScreen &&
                fullScreenDetector.isDesktopHidden(for: screen.id)
        )
        notifyWallpaperSessionChanged()
    }

    // MARK: - HTML Wallpaper (delegates to HTMLWallpaperCoordinator)

    func htmlSourceMultiplicity() -> [String: [CGDirectDisplayID]] {
        htmlCoordinator.sourceMultiplicity()
    }

    func screensRunningSameHTMLSource(as source: HTMLSource, excluding: CGDirectDisplayID) -> [Screen] {
        htmlCoordinator.screensRunningSameSource(as: source, excluding: excluding)
    }

    func setHTMLWallpaper(source: HTMLSource, config: HTMLConfig = .default, forceReload: Bool = false, for screen: Screen) {
        htmlCoordinator.setWallpaper(source: source, config: config, forceReload: forceReload, for: screen)
    }

    func setHTMLWallpaperPreservingConfig(source: HTMLSource, for screen: Screen) {
        htmlCoordinator.setWallpaperPreservingConfig(source: source, for: screen)
    }

    func setHTMLWallpaper(url: String, for screen: Screen) {
        htmlCoordinator.setWallpaper(url: url, for: screen)
    }

    func updateHTMLConfig(_ config: HTMLConfig, for screen: Screen) {
        htmlCoordinator.updateConfig(config, for: screen)
    }

    // MARK: - Metal Shader Wallpaper

    func setShaderWallpaper(preset: MetalShaderPreset, for screen: Screen) {
        let previousContent = configurationStore.get(for: screen.id)?.activeWallpaper
        var config = configurationStore.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id, wallpaper: .metalShader(preset)
        )
        config.setShaderWallpaper(preset)
        originReconciler.reconcile(
            &config,
            event: .userReplacedActiveWallpaper(previous: previousContent)
        )
        saveConfiguration(config)

        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
    }

    // MARK: - Helper Methods

    @ObservationIgnored private var refreshRateCache: [CGDirectDisplayID: Int] = [:]

    func getScreenRefreshRate(for screenID: CGDirectDisplayID) -> Int {
        if let cached = refreshRateCache[screenID] { return cached }

        guard let mode = CGDisplayCopyDisplayMode(screenID) else { return 60 }
        let rate = mode.refreshRate > 0 ? Int(mode.refreshRate) : 60
        refreshRateCache[screenID] = rate
        return rate
    }
    
    // MARK: - Playlist + Schedule (delegates to WallpaperAutomationOrchestrator)

    func updatePlaylistBookmarks(_ bookmarks: [Data], for screen: Screen) {
        automationOrchestrator.updatePlaylistBookmarks(bookmarks, for: screen)
    }

    func setPrimaryVideo(bookmark: Data, for screen: Screen) {
        automationOrchestrator.setPrimaryVideo(bookmark: bookmark, for: screen)
    }

    func replacePlaylist(ordered: [Data], primary: Data, for screen: Screen) {
        automationOrchestrator.replacePlaylist(ordered: ordered, primary: primary, for: screen)
    }

    func playPlaylistEntry(at index: Int, for screen: Screen) {
        automationOrchestrator.playPlaylistEntry(at: index, for: screen)
    }

    func updateShufflePlaylist(_ shuffle: Bool, for screen: Screen) {
        automationOrchestrator.updateShufflePlaylist(shuffle, for: screen)
    }

    func advancePlaylist(for screen: Screen) {
        automationOrchestrator.advancePlaylist(for: screen)
    }

    func regressPlaylist(for screen: Screen) {
        automationOrchestrator.regressPlaylist(for: screen)
    }

    func replaceActiveBookmark(_ bookmarkData: Data, for screen: Screen) {
        automationOrchestrator.replaceActiveBookmark(bookmarkData, for: screen)
    }

    func updateWallpaperMode(_ mode: WallpaperMode, for screen: Screen) {
        automationOrchestrator.updateWallpaperMode(mode, for: screen)
    }

    func updateScheduleSlots(_ slots: [ScheduleSlot]?, for screen: Screen) {
        automationOrchestrator.updateScheduleSlots(slots, for: screen)
    }

    func checkAndApplySchedule(for screen: Screen) {
        automationOrchestrator.checkAndApplySchedule(for: screen)
    }

    func updatePlaylistRotationMinutes(_ minutes: Int?, for screen: Screen) {
        automationOrchestrator.updatePlaylistRotationMinutes(minutes, for: screen)
    }
}
