import SwiftUI
import Combine
import LiveWallpaperCore
import Observation

@MainActor @Observable
final class ScreenManager {
    var screens: [Screen] = []
    /// Master render gate: whether ALL wallpaper pipelines may display.
    var wallpapersGloballyEnabled: Bool = ScreenManager.loadGloballyEnabled()

    static let globallyEnabledDefaultsKey = "loomscreen.wallpapers.globallyEnabled.v1"
    private static func loadGloballyEnabled() -> Bool {
        UserDefaults.standard.object(forKey: globallyEnabledDefaultsKey) as? Bool ?? true
    }

    /// Single observable snapshot of derived wallpaper-session state.
    var wallpaperSessionState = WallpaperSessionState()
    var wallpaperSessionStateVersion: UInt64 { wallpaperSessionState.version }
    var wallpaperSessionSummaryCache: WallpaperSessionSummaryCache { wallpaperSessionState.summaryCache }
    #if !LITE_BUILD
    /// Per-screen WPE import bookkeeping (last error + generation counter).
    let wpeImportTracker = WPEImportTracker()
    #endif
    /// Display-name cache for security-scoped bookmarks.
    let bookmarkDisplayNameCache = BookmarkDisplayNameCache()

    @ObservationIgnored var cleanupTasks: Set<AnyCancellable> = []
    /// One-way application-termination latch.
    @ObservationIgnored var isTerminating = false
    @ObservationIgnored let displayRegistry: any DisplayRegistering
    @ObservationIgnored let featureCatalog: FeatureCatalog
    @ObservationIgnored let originReconciler: any OriginReconciler
    @ObservationIgnored let configurationStore = WallpaperConfigurationStore()
    @ObservationIgnored let ambientSessionBuilder = AmbientWallpaperSessionBuilder()
    @ObservationIgnored private let automationCoordinator = WallpaperAutomationCoordinator()
    @ObservationIgnored let powerMonitor: any PowerMonitoring
    @ObservationIgnored let playbackStateSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored let fullScreenDetector: any FullScreenDetecting
    @ObservationIgnored private let playableVideoLoader: any PlayableVideoLoading
    @ObservationIgnored let memoryPressureWatcher: any MemoryPressureWatching
    @ObservationIgnored let restoresSavedWallpapersOnScreenRefresh: Bool
    @ObservationIgnored var lastScreenSignatures: [CGDirectDisplayID: ScreenConfigurationSignature] = [:]
    @ObservationIgnored var transientRuntimeErrors: [CGDirectDisplayID: WallpaperRuntimeError] = [:]
    /// App Nap throttles an `LSUIElement` accessory app's render loop to ~1fps the moment another app becomes active, freezing the wallpaper whenever the user focuses any other window.
    @ObservationIgnored var renderingActivityToken: (any NSObjectProtocol)?
    enum UserAbsenceReason: Hashable {
        case screenLocked
        case displaySleep
        case systemSleep
    }
    /// Reasons the user is not watching the desktop.
    @ObservationIgnored var userAbsenceReasons: Set<UserAbsenceReason> = []
    var isUserAbsent: Bool { !userAbsenceReasons.isEmpty }
    /// Feeds memory pressure into the performance policy without changing user playback intent.
    @ObservationIgnored var isUnderMemoryPressure = false
    /// Coordinates per-screen playback configuration mutations + transition tokens.
    @ObservationIgnored lazy var playbackCoordinator = PlaybackCoordinator(
        configurationStore: configurationStore,
        playableVideoLoader: playableVideoLoader,
        applyPolicy: { [weak self] screen in
            self?.applyPerformancePolicy(to: screen)
        },
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
        originReconciler: originReconciler,
        isGloballyEnabled: { [weak self] in
            self?.wallpapersGloballyEnabled ?? true
        },
        isRuntimeInstallationAllowed: { [weak self] in
            guard let self else { return false }
            return !self.isTerminating
        }
    )
    /// Lazy because the `saveConfiguration` / `restoreWallpaperSession`
    /// callbacks capture `self` (matches `playbackCoordinator`'s pattern).
    #if !LITE_BUILD
    /// Shares the `wpeImportTracker` reference so both this coordinator and
    /// the view-facing `wpeImportError(for:)` reader observe the same state.
    @ObservationIgnored lazy var wpeImportCoordinator = WPEImportCoordinator(
        tracker: wpeImportTracker,
        configurationStore: configurationStore,
        saveConfiguration: { [weak self] config in
            self?.saveConfiguration(config)
        },
        restoreWallpaperSession: { [weak self] screen, config, preservingState in
            self?.restoreWallpaperSession(for: screen, configuration: config, preservingState: preservingState)
        },
        persistOriginBookmarkRefresh: { [weak self] origin, refreshed in
            self?.persistRuntimeWPEBookmarkRefresh(origin: origin, with: refreshed)
        },
        isLifecycleActive: { [weak self] in
            guard let self else { return false }
            return !self.isTerminating
        }
    )
    #endif
    /// Centralises the write side of ScreenConfiguration persistence (save / remove / prune / validate / display-name priming).
    @ObservationIgnored lazy var persistence = WallpaperPersistenceCoordinator(
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
    @ObservationIgnored var transitionRegistry: PlaybackTransitionRegistry {
        playbackCoordinator.transition
    }
    /// Owns playlist + schedule automation, including the `WallpaperAutomationCoordinator.start(...)` wiring.
    @ObservationIgnored lazy var automationOrchestrator = WallpaperAutomationOrchestrator(
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
    /// Owns HTML wallpaper management (setters + multi-instance audio-leader + trust evaluation).
    @ObservationIgnored lazy var htmlCoordinator = HTMLWallpaperCoordinator(
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
        originReconciler: originReconciler,
        prepareSource: { [weak self] source, bookmarkID, wpeOrigin in
            guard let self else { return source }
            return self.ambientSessionBuilder.refreshingHTMLSource(
                source,
                onBookmarkRefresh: { [weak self] original, refreshed in
                    self?.persistRuntimeHTMLBookmarkRefresh(
                        matching: original,
                        with: refreshed,
                        bookmarkID: bookmarkID,
                        ownerOrigin: wpeOrigin
                    )
                }
            )
        }
    )
    /// Owns the CIFilter video-effects pipeline + weather-reactive monitor.
    @ObservationIgnored var effectsCoordinatorWasInitialized = false
    @ObservationIgnored lazy var effectsCoordinator: WallpaperEffectsCoordinator = {
        self.effectsCoordinatorWasInitialized = true
        return WallpaperEffectsCoordinator(
            configurationStore: self.configurationStore,
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
    }()
    /// Exposed for the WeatherLocation settings view, which reads `currentParticleEffect` / `currentEffectAdjustments` directly and triggers `refresh()` on user gestures.
    var weatherService: WeatherReactiveService {
        let coordinator = effectsCoordinator
        // SwiftUI may reevaluate a settings/inspector body while AppKit is waiting for termination.
        if isTerminating {
            coordinator.shutdown()
        }
        return coordinator.weatherService
    }
    @ObservationIgnored lazy var lockScreenSnapshotCoordinator = LockScreenSnapshotCoordinator { [weak self] in
        self?.captureDesktopSnapshotsForLockIfNeeded()
    }
    /// Bumped each time `observeFullScreenChanges()` registers a new observer.
    @ObservationIgnored var fullScreenTrackingGeneration: UInt64 = 0
    /// Per-display latch for the *occlusion* arm of the adaptive frame-rate throttle so the policy can apply hysteresis (avoids flapping as window coverage hovers near the enter/exit thresholds).
    @ObservationIgnored var adaptiveFrameRateOcclusionThrottled: [CGDirectDisplayID: Bool] = [:]

    /// Screens whose last-resolved profile was `.suspended`.
    @ObservationIgnored var suspendedScreenIDs: Set<CGDirectDisplayID> = []

    // MARK: - Initialization
    init(startupOptions: ScreenManagerStartupOptions) {
        displayRegistry = startupOptions.displayRegistry ?? DisplayRegistry()
        featureCatalog = startupOptions.featureCatalog
        originReconciler = startupOptions.originReconciler
        powerMonitor = startupOptions.powerMonitor ?? PowerMonitor.shared
        fullScreenDetector = startupOptions.fullScreenDetector ?? FullScreenDetector()
        playableVideoLoader = startupOptions.playableVideoLoader ?? PlayableVideoLoader()
        memoryPressureWatcher = startupOptions.memoryPressureWatcher
        restoresSavedWallpapersOnScreenRefresh = startupOptions.restoreSavedWallpapers

        Logger.notice("ScreenManager initializing", category: .screenManager)
        setupPowerMonitoring()
        setupScreenObservers()
        setupMemoryPressureMonitoring()
        setupFullScreenDetection()
        if featureCatalog.isEnabled(.lockScreenSnapshots) {
            _ = lockScreenSnapshotCoordinator
        }

        NotificationCenter.default.publisher(for: WallpaperVideoPlayer.didChangePlaybackStateNotification)
            .sink { [weak self] _ in
                self?.markWallpaperSessionStateChanged()
            }
            .store(in: &cleanupTasks)

        refreshScreens()
        if startupOptions.startAutomation {
            if featureCatalog.isEnabled(.playlists) || featureCatalog.isEnabled(.scheduleAutomation) {
                automationOrchestrator.startMonitoring()
            }
            if featureCatalog.isEnabled(.weatherReactive) {
                startWeatherMonitoring()
            }
        }
        Logger.notice("ScreenManager initialization complete", category: .screenManager)
    }

    // MARK: - Public Interface
    func reloadWallpaperForScreen(_ screen: Screen) {
        guard !isTerminating else { return }
        Logger.info("Manually reloading wallpaper for screen \(screen.id)", category: .screenManager)

        guard let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else {
            releaseRuntimeSession(screen)
            return
        }

        primeBookmarkDisplayNames(from: configuration)
        releaseRuntimeSession(screen)
        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }
    
    // MARK: - Helper Methods

    @ObservationIgnored var refreshRateCache: [CGDirectDisplayID: Int] = [:]

    func getScreenRefreshRate(for screenID: CGDirectDisplayID) -> Int {
        if let cached = refreshRateCache[screenID] { return cached }

        guard let mode = CGDisplayCopyDisplayMode(screenID) else { return 60 }
        let rate = mode.refreshRate > 0 ? Int(mode.refreshRate) : 60
        refreshRateCache[screenID] = rate
        return rate
    }
    
}
