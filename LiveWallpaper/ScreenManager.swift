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
    /// Master render gate: whether ALL wallpaper pipelines may display. Persisted
    /// and INDEPENDENT of per-screen play/pause — the menu-bar master switch
    /// reflects exactly this flag, not whether any screen happens to be playing.
    private(set) var wallpapersGloballyEnabled: Bool = ScreenManager.loadGloballyEnabled()

    private static let globallyEnabledDefaultsKey = "loomscreen.wallpapers.globallyEnabled.v1"
    private static func loadGloballyEnabled() -> Bool {
        UserDefaults.standard.object(forKey: globallyEnabledDefaultsKey) as? Bool ?? true
    }

    /// Single observable snapshot of derived wallpaper-session state. Every
    /// mutation flows through `commitWallpaperSessionState()`, which builds
    /// a new value, compares it against the current snapshot, and assigns
    /// only when the diff is real — at most one observation invalidation
    /// per session change.
    private(set) var wallpaperSessionState = WallpaperSessionState()
    var wallpaperSessionStateVersion: UInt64 { wallpaperSessionState.version }
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
    @ObservationIgnored private let powerMonitor: any PowerMonitoring
    @ObservationIgnored private let playbackStateSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored private let fullScreenDetector: any FullScreenDetecting
    @ObservationIgnored private let playableVideoLoader: any PlayableVideoLoading
    @ObservationIgnored private let restoresSavedWallpapersOnScreenRefresh: Bool
    @ObservationIgnored private var lastScreenSignatures: [CGDirectDisplayID: ScreenConfigurationSignature] = [:]
    @ObservationIgnored private var transientRuntimeErrors: [CGDirectDisplayID: WallpaperRuntimeError] = [:]
    /// App Nap throttles an `LSUIElement` accessory app's render loop to ~1fps
    /// the moment another app becomes active, freezing the wallpaper whenever
    /// the user focuses any other window. Held while a wallpaper is on screen
    /// to keep the MTKView clock at full rate in the background; released when
    /// the last session goes away. See `refreshAppNapAssertion()`.
    @ObservationIgnored private var renderingActivityToken: (any NSObjectProtocol)?
    private enum UserAbsenceReason: Hashable {
        case screenLocked
        case displaySleep
        case systemSleep
    }
    /// Reasons the user is not watching the desktop. Folded into the effective
    /// performance profile (`isUserAbsent`) so lock / display-sleep / system
    /// sleep suspend through the single policy path instead of a parallel
    /// pause/resume overlay.
    @ObservationIgnored private var userAbsenceReasons: Set<UserAbsenceReason> = []
    private var isUserAbsent: Bool { !userAbsenceReasons.isEmpty }
    /// No display is lit when the panels or the whole machine are asleep — no
    /// render or memory-pressure response is possible, so SystemMonitor's 2s
    /// poll is parked here (Pro-only; gated on `.systemMonitor`).
    private var allDisplaysAsleep: Bool {
        userAbsenceReasons.contains(.displaySleep) || userAbsenceReasons.contains(.systemSleep)
    }
    /// Tracks whether we currently hold a SystemMonitor reference, so the
    /// reference-counted start/stop stays balanced across sleep/wake churn.
    @ObservationIgnored private var systemMonitorActive = false
    /// System memory pressure, folded into the performance policy so a
    /// low-memory condition suspends every wallpaper type and **auto-resumes**
    /// once memory recovers — unlike the old `handleLowMemory` path, which
    /// cleared video play-intent and never restored it.
    @ObservationIgnored private var isUnderMemoryPressure = false
    /// Coordinates per-screen playback configuration mutations + transition
    /// tokens. Lazy because it captures `self` for the effect-application and
    /// refresh-rate-lookup callbacks; the stored properties used by those
    /// callbacks (`videoEffectsApplier`, `refreshRateCache`, etc.) are already
    /// initialised by the time the lazy var is touched.
    @ObservationIgnored private lazy var playbackCoordinator = PlaybackCoordinator(
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
        }
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
    /// Bumped each time `observeFullScreenChanges()` registers a new observer.
    /// The onChange callback short-circuits when its captured generation no
    /// longer matches the latest value, so accidentally re-registering does
    /// not cascade into stacked callbacks.
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

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Logger.info(
                    "Thermal state changed to \(ProcessInfo.processInfo.thermalState); refreshing wallpaper performance policy",
                    category: .powerMonitor
                )
                self.refreshPerformancePolicyForAllScreens()
            }
            .store(in: &cleanupTasks)

        // Low Power Mode toggles flip `GameModeDetector.shared.isActive` without
        // changing the frontmost app, so we need a dedicated subscription
        // here — otherwise the policy refresh would wait for the next
        // unrelated event. The notification name is the AppKit/Foundation
        // Obj-C constant; Swift doesn't surface a typed alias on macOS.
        NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Logger.info(
                    "Power state changed (Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)); refreshing wallpaper performance policy",
                    category: .powerMonitor
                )
                self.refreshPerformancePolicyForAllScreens()
            }
            .store(in: &cleanupTasks)

        // GameMode + per-app pause rules (frontmost trigger) piggyback on
        // frontmost-app activations — flipping to / from Steam, a game, or a
        // rule-listed app re-evaluates the policy.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshPerformancePolicyForAllScreens()
            }
            .store(in: &cleanupTasks)

        // Per-app pause rules with the "while running" trigger need to react to
        // launch / quit too (an app can start without becoming frontmost). These
        // fire only on actual launch/quit, so there's no idle cost.
        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else { return }
            // Cheap no-op unless a "running"-trigger rule exists.
            guard SettingsManager.shared.loadGlobalSettings()
                .applicationPerformanceRules.contains(where: { $0.trigger == .running }) else { return }
            self.refreshPerformancePolicyForAllScreens()
        }
        .store(in: &cleanupTasks)

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

        // Display sleep（仅显示器睡眠，整机仍在跑）。区别于上面的 willSleep/didWake
        // （整机睡眠）和下面的 screenIsLocked（用户锁屏，显示器仍亮）。
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in
                self?.handleDisplaySleep()
            }
            .store(in: &cleanupTasks)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in
                self?.handleDisplayWake()
            }
            .store(in: &cleanupTasks)

        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .sink { [weak self] _ in
                self?.handleScreenLocked()
            }
            .store(in: &cleanupTasks)

        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .sink { [weak self] _ in
                self?.handleScreenUnlocked()
            }
            .store(in: &cleanupTasks)
    }

    private func handleScreenLocked() {
        Logger.info("Screen locked — suspending wallpaper sessions", category: .lifecycle)
        setUserAbsence(.screenLocked, present: true)
    }

    private func handleDisplaySleep() {
        Logger.info("Display asleep — suspending wallpaper sessions", category: .lifecycle)
        setUserAbsence(.displaySleep, present: true)
    }

    private func handleDisplayWake() {
        Logger.info("Display awake — restoring wallpaper sessions", category: .lifecycle)
        setUserAbsence(.displaySleep, present: false)
    }

    private func handleScreenUnlocked() {
        Logger.info("Screen unlocked — restoring wallpaper sessions", category: .lifecycle)
        setUserAbsence(.screenLocked, present: false)
    }

    /// Lock screen and display sleep both mean "user is not watching". They
    /// fold into the effective performance profile via `isUserAbsent`, so a
    /// single policy refresh suspends or restores every session (respecting
    /// each video's `userIntendsToPlay`) — no separate pause/resume overlay.
    private func setUserAbsence(_ reason: UserAbsenceReason, present: Bool) {
        let changed = present
            ? userAbsenceReasons.insert(reason).inserted
            : (userAbsenceReasons.remove(reason) != nil)
        guard changed else { return }
        reconcileSystemMonitor()
        refreshPerformancePolicyForAllScreens()
    }

    /// Park / resume SystemMonitor's poll alongside display availability.
    /// Conservative gate (all displays asleep) rather than per-session, because
    /// the system-memory-pressure warning that drives `setMemoryPressure` is
    /// derived inside SystemMonitor's own sampling loop — stopping the poll
    /// stops that warning, so we only park it when no display can render at all.
    private func reconcileSystemMonitor() {
        guard featureCatalog.isEnabled(.systemMonitor) else { return }
        let shouldRun = !allDisplaysAsleep
        guard shouldRun != systemMonitorActive else { return }
        systemMonitorActive = shouldRun
        if shouldRun {
            SystemMonitor.shared.startMonitoring()
        } else {
            SystemMonitor.shared.stopMonitoring()
        }
    }

    private func handleScreenParameterChange() {
        let current = ScreenConfigurationSignature.currentLayout()
        if current == lastScreenSignatures && !screens.isEmpty {
            Logger.debug("Screen parameters unchanged — skipping refresh", category: .screenManager)
            return
        }
        lastScreenSignatures = current

        refreshRateCache.removeAll()
        refreshScreens(preserveRuntimeSessions: true)

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.updateAllWindowFrames()
            try? await Task.sleep(for: .milliseconds(500))
            self?.updateAllWindowFrames()
        }

    }

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
        systemMonitorActive = true

        NotificationCenter.default.publisher(for: .systemMemoryWarning)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setMemoryPressure(true)
            }
            .store(in: &cleanupTasks)

        NotificationCenter.default.publisher(for: .systemMemoryNormal)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setMemoryPressure(false)
            }
            .store(in: &cleanupTasks)
    }

    private func setupFullScreenDetection() {
        observeFullScreenChanges()
        fullScreenDetector.checkNow()
        handleFullScreenChange(fullScreenDetector.hiddenScreens)
    }

    private func observeFullScreenChanges() {
        fullScreenTrackingGeneration &+= 1
        let generation = fullScreenTrackingGeneration
        withObservationTracking {
            _ = fullScreenDetector.hiddenScreens
            _ = fullScreenDetector.occludedScreens
            // Adaptive throttle reacts to partial coverage below the 0.85
            // pause cutoff, so track the (quantized) fraction too.
            _ = fullScreenDetector.occlusionFractions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.fullScreenTrackingGeneration == generation else { return }
                self.handleFullScreenChange(self.fullScreenDetector.hiddenScreens)
                self.observeFullScreenChanges()
            }
        }
    }

    /// Full-screen / window-occlusion changes fold into the effective profile
    /// like every other condition; a single policy refresh applies the unified
    /// play/pause decision. The `hiddenScreens` snapshot is now informational —
    /// the policy reads the detector live.
    private func handleFullScreenChange(_ hiddenScreens: [CGDirectDisplayID: Bool]) {
        refreshPerformancePolicyForAllScreens()
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

        // Enforce a persisted "off" master gate. With the build gate in
        // `restoreWallpaperSession`, disabled screens never build a session
        // above; this is the safety net that also tears down any session
        // adopted/preserved across a screen refresh so nothing stays resident.
        if !wallpapersGloballyEnabled {
            applyGlobalRenderGate()
        }

        NotificationCenter.default.post(name: .screensRefreshed, object: nil)
    }

    func clearWallpaperForScreen(_ screen: Screen) {
        Logger.info("Clearing wallpaper for screen \(screen.id)", category: .screenManager)
        releaseRuntimeSession(screen)
        persistence.remove(for: screen.id)
        notifyWallpaperSessionChanged()
    }

    /// Clear only one wallpaper type for this screen — drops that type's saved
    /// state (saved video bookmark, saved HTML source, etc.). If the
    /// currently-active wallpaper is the type being cleared, falls back to
    /// the next saved type (video → html) so the screen doesn't blank out
    /// while the user still has a usable picks from another tab; only when
    /// no fallback exists does this collapse to a full `clearWallpaperForScreen`.
    func clearWallpaperOfType(_ type: WallpaperType, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }

        let wasActive = (config.activeWallpaper.wallpaperType == type)
        // Switching away from an active scene drops its origin metadata too, so a
        // later reload can't re-resolve a deleted scene from a stale `wpeOrigin`.
        if wasActive, type == .scene {
            config.wpeOrigin = nil
        }

        switch type {
        case .video:
            config.savedVideoBookmarkData = nil
            config.playlistBookmarks = nil
            config.playlistPrimaryIndex = nil
        case .html:
            config.savedHTMLSource = nil
            config.savedHTMLConfig = nil
        case .scene:
            config.savedSceneDescriptor = nil
        case .metalShader:
            break
        }

        guard wasActive else {
            saveConfiguration(config)
            return
        }

        if type != .video, config.activateSavedVideoWallpaper() {
            saveConfiguration(config)
            restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
            return
        }

        if type != .html, config.activateSavedHTMLWallpaper() {
            saveConfiguration(config)
            restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
            return
        }

        clearWallpaperForScreen(screen)
    }

    /// Tears down the live runtime session without touching persistence.
    private func releaseRuntimeSession(_ screen: Screen) {
        adaptiveFrameRateOcclusionThrottled[screen.id] = nil
        bumpTransition(for: screen.id)
        effectsCoordinator.cancelInflight(for: screen.id)
        transitionRegistry.cancelAssetReadiness(for: screen.id)
        setTransientRuntimeError(nil, for: screen.id)
        screen.resetRuntimeSession()
        playbackCoordinator.refreshVideoAudioLeadership()
        refreshAppNapAssertion()
    }

    /// App-termination teardown: synchronously tears down every render session
    /// (each `cleanup()` pauses its AVPlayer, releases its WKWebView / Metal
    /// renderer, and closes its window) and parks SystemMonitor. Bounded — just
    /// a loop of in-process releases, no I/O — so it stays inside the terminate
    /// watchdog. Unlike `resetAllWallpaperSessions()` it skips config-cache
    /// clearing and async UI notifications, which are pointless mid-exit.
    func tearDownForTermination() {
        for screen in screens {
            releaseRuntimeSession(screen)
        }
        if systemMonitorActive {
            systemMonitorActive = false
            SystemMonitor.shared.stopMonitoring()
        }
    }

    func resetAllWallpaperSessions() {
        let snapshot = screens
        for screen in snapshot {
            releaseRuntimeSession(screen)
        }
        configurationStore.clearCache()
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

    /// Light launch-time pass: prunes configurations whose local resource bookmark is no longer resolvable.
    func pruneInvalidConfigurationsIfNeeded() {
        persistence.pruneInvalidConfigurations()
    }

    private func loadConfigurationForScreen(_ screen: Screen) {
        if screen.videoPlayer != nil {
            if let cachedConfig = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) {
                primeBookmarkDisplayNames(from: cachedConfig)
                applyConfiguration(cachedConfig, to: screen, preservingState: true)
            }
            return
        }

        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        primeBookmarkDisplayNames(from: config)
        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
    }

    private func restoreWallpaperSession(
        for screen: Screen,
        configuration: ScreenConfiguration,
        preservingState: Bool
    ) {
        // Master gate: when wallpapers are globally disabled we keep the
        // configuration persisted but do NOT build a live session. This avoids
        // allocating the renderer / scene runtime / decoded assets only to
        // suspend them — the session is (re)built by `applyGlobalRenderGate()`
        // when the master switch is turned back on.
        guard wallpapersGloballyEnabled else {
            if screen.runtimeSession != nil { releaseRuntimeSession(screen) }
            // No live session is built, but the caller has just persisted this
            // configuration. Refresh the derived session state so a wallpaper
            // assigned while the gate is off is reflected as configured-but-
            // `.off` (keeping the master switch enabled) — mirrors the video
            // path's refresh in `PlaybackCoordinator.setupVideoPlayback`.
            notifyWallpaperSessionChanged()
            return
        }

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
        case .metalShader(let shaderSource):
            activateAmbientWallpaper(.metalShader(shaderSource), for: screen, configuration: configuration)
        case .scene(let descriptor):
            activateAmbientWallpaper(.scene(descriptor), for: screen, configuration: configuration)
        }
    }
    
    // MARK: - Video Management

    /// Replaces the primary video while preserving per-screen settings.
    func setVideo(url: URL, bookmarkData: Data, packageEntryName: String? = nil, for screen: Screen) {
        recordBookmarkDisplayName(bookmarkData, name: url.lastPathComponent)
        playbackCoordinator.setVideo(
            url: url,
            bookmarkData: bookmarkData,
            packageEntryName: packageEntryName,
            for: screen
        )
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
        wallpaperSessionSummaryCache.summary(for: screen.id, fallback: effectiveSummary(for: screen))
    }

    /// Per-screen summary that accounts for the master render gate. With a live
    /// session we use its own summary. Without one we still report
    /// configured-but-`.off` when the master switch is off and a wallpaper is
    /// persisted — so the overview stays `.off` (and the menu-bar master switch
    /// stays enabled to turn rendering back on) instead of collapsing to
    /// `.notConfigured` now that the gate tears sessions down to free memory.
    private func effectiveSummary(for screen: Screen) -> WallpaperSessionSummary {
        if screen.runtimeSession != nil {
            return screen.wallpaperSessionSummary
        }
        if !wallpapersGloballyEnabled, let type = persistedWallpaperType(for: screen) {
            return WallpaperSessionSummary(
                wallpaperType: type,
                activity: .off,
                supportsPlaybackControl: false,
                subtitle: nil
            )
        }
        return screen.wallpaperSessionSummary
    }

    /// The wallpaper type a screen would render from its persisted
    /// configuration, or `nil` when nothing valid is assigned. Uses the same
    /// validity gate as `restoreWallpaperSession` so an empty/malformed config
    /// reads as "not configured".
    private func persistedWallpaperType(for screen: Screen) -> WallpaperType? {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              WallpaperSessionDefinition(configuration: config) != nil else { return nil }
        return config.activeWallpaper.wallpaperType
    }

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

    /// Subscribes the manager to a session's error changes so the SwiftUI banner refreshes when a player or web view starts / clears a failure.
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
        guard let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              let definition = WallpaperSessionDefinition(configuration: configuration) else { return nil }

        return definition.displayName(using: { bookmarkDisplayName(for: $0) })
    }

    func bookmarkDisplayName(for bookmarkData: Data) -> String? {
        bookmarkDisplayNameCache.name(for: bookmarkData)
    }

    func currentVideoDisplayName(for screen: Screen) -> String? {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return nil }
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

    /// Builds the next session-state snapshot and commits it iff something actually changed.
    private func commitWallpaperSessionState(includePollingRefresh: Bool = false) {
        var next = wallpaperSessionState
        next.summaryCache = WallpaperSessionSummaryCache(
            entries: screens.map { ($0.id, effectiveSummary(for: $0)) }
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

        // Decide from user INTENT, not actual playback: a policy-suspended
        // video reads `isPlaying == false` but the user still "intends" to
        // play, so toggling must flip intent, not chase the suppressed state.
        let anyIntendsToPlay = screens.contains { $0.playbackController?.userIntendsToPlay ?? false }

        Logger.info("Toggling global playback: \(anyIntendsToPlay ? "pausing" : "playing") all videos", category: .videoPlayer)

        for screen in screens {
            guard let playback = screen.playbackController else { continue }
            if anyIntendsToPlay {
                playback.pause()
            } else {
                playback.play()
            }
        }

        updatePlaybackState()
    }

    /// Per-screen play/pause toggle. Video sessions also post a playback-state
    /// notification that triggers a commit, but scene/HTML sessions only mutate
    /// `userIntendsToPlay`, so this commits the derived session state itself to
    /// refresh the menu-bar / inspector UI immediately.
    func togglePlayback(for screen: Screen) {
        guard let playback = screen.playbackController else { return }
        if playback.userIntendsToPlay {
            playback.pause()
        } else {
            playback.play()
        }
        updatePlaybackState()
    }

    /// Master render gate. Toggles whether wallpaper pipelines exist at all:
    /// disabling tears every session down to free its memory, enabling rebuilds
    /// them from persisted configuration (see `applyGlobalRenderGate`). The flag
    /// is persisted and is the single source of truth for the menu-bar master
    /// switch. Note: because sessions are destroyed rather than suspended,
    /// transient per-screen playback state (a manual pause is not persisted
    /// anywhere) is not carried across an off→on cycle — rebuilt screens follow
    /// the normal startup playback policy, exactly as on app relaunch.
    func setWallpapersEnabled(_ enabled: Bool) {
        wallpapersGloballyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.globallyEnabledDefaultsKey)
        Logger.info("\(enabled ? "Enabling" : "Disabling") all wallpaper rendering (master gate)", category: .screenManager)

        applyGlobalRenderGate()
        markWallpaperSessionStateChanged()
    }

    /// Apply the master gate to every screen. When enabled, builds any session
    /// that is missing (from its persisted configuration) and makes any
    /// already-live one visible, then re-runs the performance policy so the
    /// gate never decides quality/suspended itself. When disabled, fully tears
    /// each session down so its GPU textures, scene runtime, and decoded assets
    /// are released — rather than leaving a suspended-but-resident renderer
    /// holding memory. Idempotent and safe to call across launches and after
    /// new wallpapers are assigned.
    func applyGlobalRenderGate() {
        for screen in screens {
            if wallpapersGloballyEnabled {
                if screen.runtimeSession == nil {
                    // Rendering is permitted again — rebuild from the persisted
                    // configuration. No-op for screens without a saved wallpaper.
                    // The build path applies the current performance policy itself.
                    loadConfigurationForScreen(screen)
                } else {
                    // Already-live session (idempotent re-enable): only ensure
                    // the window is visible. Whether it runs or stays suspended
                    // is decided by the performance policy below — never a blind
                    // resume() that would override power / thermal / full-screen
                    // / app-rule state.
                    screen.runtimeSession?.show()
                }
            } else if screen.runtimeSession != nil {
                releaseRuntimeSession(screen)
            }
        }

        // Single source of truth for "how hard a live session works". Re-running
        // the policy after enabling keeps the master gate (a lifecycle axis)
        // from bypassing the performance-profile axis. Skipped while disabled —
        // there are no live sessions to target.
        if wallpapersGloballyEnabled {
            refreshPerformancePolicyForAllScreens()
        }
    }
    
    // MARK: - Power Management
    /// Power changes no longer carry their own play/pause logic — they fold
    /// into the effective performance profile like every other condition, so a
    /// single refresh applies the unified decision (`userIntendsToPlay` for
    /// video, profile for ambient) across all screens.
    private func handlePowerStateChange(_ powerSource: PowerMonitor.PowerSource) {
        refreshPerformancePolicyForAllScreens()
    }

    /// Per-display latch for the *occlusion* arm of the adaptive frame-rate
    /// throttle so the policy can apply hysteresis (avoids flapping as window
    /// coverage hovers near the enter/exit thresholds). Tracks occlusion alone —
    /// folding in the battery arm would let unplugging at ~45% coverage stay
    /// throttled on the lower exit threshold. Cleared on session release.
    @ObservationIgnored private var adaptiveFrameRateOcclusionThrottled: [CGDirectDisplayID: Bool] = [:]

    /// Single source of truth for resolving + applying the performance policy to
    /// one screen. Every raw signal is gathered here (via `policyInputs`), so no
    /// other type re-assembles the rule inputs — `PlaybackCoordinator` calls back
    /// into this instead of duplicating the gathering.
    @discardableResult
    func applyPerformancePolicy(to screen: Screen) -> WallpaperPerformanceProfile {
        let settings = SettingsManager.shared.loadGlobalSettings()
        return resolveAndApplyPerformanceState(
            to: screen,
            settings: settings,
            applicationRuleActive: currentApplicationRuleActive(settings),
            frontmostExcluded: ApplicationPerformanceRuleEngine.isFrontmostExcluded(for: settings)
        )
    }

    /// Resolves the universal suspend/quality profile and applies it together
    /// with the scene-only adaptive frame-rate throttle — the single place that
    /// pairs the two so a future edit can't drift the all-screens and
    /// single-screen paths apart. Context (`settings` and the rule flags) is
    /// passed in so the all-screens loop computes it once.
    @discardableResult
    private func resolveAndApplyPerformanceState(
        to screen: Screen,
        settings: GlobalSettings,
        applicationRuleActive: Bool,
        frontmostExcluded: Bool
    ) -> WallpaperPerformanceProfile {
        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: policyInputs(
                for: screen,
                applicationRuleActive: applicationRuleActive,
                frontmostExcluded: frontmostExcluded
            ),
            settings: settings
        )
        screen.runtimeSession?.applyPerformanceProfile(profile)
        applyAdaptiveFrameRate(to: screen, settings: settings)
        return profile
    }

    /// Layers the adaptive background frame-rate throttle on top of the binary
    /// play/pause profile. Pixel-identical; only the presented frame *rate*
    /// changes, which on Apple Silicon is the dominant GPU-power driver. Scene
    /// renderer only — the video path uses a separate composition cap. No-op in
    /// Lite (no scene renderer).
    private func applyAdaptiveFrameRate(to screen: Screen, settings: GlobalSettings) {
        #if !LITE_BUILD
        guard let scene = screen.runtimeSession as? SceneWallpaperSession,
              let controller = scene.frameRateController else {
            adaptiveFrameRateOcclusionThrottled[screen.id] = nil
            return
        }
        // Disabling the setting must actively release any live throttle, not
        // just stop computing one.
        guard settings.adaptiveFrameRateEnabled else {
            adaptiveFrameRateOcclusionThrottled[screen.id] = nil
            controller.setAdaptiveFrameRateThrottle(false)
            return
        }
        let occlusionThrottled = AdaptiveFrameRatePolicy.shouldThrottleForOcclusion(
            occlusionFraction: fullScreenDetector.occlusionFraction(for: screen.id),
            currentlyThrottled: adaptiveFrameRateOcclusionThrottled[screen.id] ?? false
        )
        adaptiveFrameRateOcclusionThrottled[screen.id] = occlusionThrottled
        let shouldThrottle = AdaptiveFrameRatePolicy.shouldThrottle(
            enabled: true,
            occlusionThrottled: occlusionThrottled,
            onBattery: powerMonitor.currentPowerSource.isOnBattery,
            pausesOnBattery: settings.globalPauseOnBattery
        )
        controller.setAdaptiveFrameRateThrottle(shouldThrottle)
        #endif
    }

    /// Snapshots the current *raw* system state for `screen`. The `GlobalSettings`
    /// gating lives in `WallpaperPolicyEngine`, so detector/state readings are
    /// passed through ungated.
    private func policyInputs(
        for screen: Screen,
        applicationRuleActive: Bool,
        frontmostExcluded: Bool
    ) -> WallpaperPolicyInputs {
        WallpaperPolicyInputs(
            powerSource: powerMonitor.currentPowerSource,
            isHiddenByFullScreen: fullScreenDetector.isDesktopHidden(for: screen.id),
            isWindowOccluding: fullScreenDetector.isDesktopOccluded(for: screen.id),
            isApplicationRuleActive: applicationRuleActive,
            thermalState: ProcessInfo.processInfo.thermalState,
            isGameModeActive: GameModeDetector.shared.isActive,
            isUserAbsent: isUserAbsent,
            isUnderMemoryPressure: isUnderMemoryPressure,
            isFrontmostExcludedByRule: frontmostExcluded
        )
    }

    private func currentApplicationRuleActive(_ globalSettings: GlobalSettings) -> Bool {
        ApplicationPerformanceRuleEngine.isActive(for: globalSettings)
    }

    private func refreshPerformancePolicyForAllScreens() {
        let settings = SettingsManager.shared.loadGlobalSettings()
        let applicationRuleActive = currentApplicationRuleActive(settings)
        let frontmostExcluded = ApplicationPerformanceRuleEngine.isFrontmostExcluded(for: settings)
        for screen in screens {
            resolveAndApplyPerformanceState(
                to: screen,
                settings: settings,
                applicationRuleActive: applicationRuleActive,
                frontmostExcluded: frontmostExcluded
            )
        }
        // A policy refresh always commits the derived session state, so observers
        // can't leave the SwiftUI layer out of sync with the render loops by
        // forgetting a trailing updatePlaybackState() call.
        commitWallpaperSessionState()
    }

    /// Hold a `.userInitiated` activity assertion whenever ≥1 wallpaper session
    /// is live, so macOS doesn't App-Nap our background render loop down to
    /// ~1fps when the user focuses another window. `.userInitiated` disables
    /// App Nap only — it does NOT keep the display or system awake, so the Mac
    /// still sleeps on its own schedule. Released once the last session ends.
    private func refreshAppNapAssertion() {
        let isRendering = screens.contains { $0.runtimeSession != nil }
        if isRendering {
            guard renderingActivityToken == nil else { return }
            renderingActivityToken = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated,
                reason: "Rendering live wallpaper"
            )
        } else if let token = renderingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            renderingActivityToken = nil
        }
    }

    private func updateFullScreenFallbackPolling() {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let hasConfiguredSessions = wallpaperSessionSummaries.contains { $0.isConfigured }
        let hasConfiguredSceneSessions = wallpaperSessionSummaries.contains {
            $0.isConfigured && $0.wallpaperType == .scene
        }
        let shouldEnablePolling = WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: globalSettings,
            hasConfiguredWallpaperSessions: hasConfiguredSessions,
            hasConfiguredSceneSessions: hasConfiguredSceneSessions
        )

        fullScreenDetector.setFallbackPollingEnabled(shouldEnablePolling)
    }

    func handleGlobalSettingsChanged() {
        updateFullScreenFallbackPolling()
        refreshPerformancePolicyForAllScreens()
    }
    
    // MARK: - Memory Management
    /// Folds memory pressure into the unified performance policy. Suspends every
    /// wallpaper type while pressure holds and auto-resumes when it clears,
    /// without ever touching the user's play/pause intent.
    private func setMemoryPressure(_ active: Bool) {
        guard isUnderMemoryPressure != active else { return }
        isUnderMemoryPressure = active
        Logger.notice(
            active ? "Memory pressure: suspending wallpapers" : "Memory pressure cleared: restoring wallpapers",
            category: .memory
        )
        refreshPerformancePolicyForAllScreens()
    }
    
    // MARK: - System Events
    private func handleSystemSleep() {
        Logger.info("System sleep detected", category: .lifecycle)
        setUserAbsence(.systemSleep, present: true)
    }

    private func handleSystemWake() {
        Logger.info("System wake detected", category: .lifecycle)
        refreshScreens()
        powerMonitor.refreshPowerStatus()
        setUserAbsence(.systemSleep, present: false)
    }

    private func captureDesktopSnapshotsForLockIfNeeded() {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        guard globalSettings.preservePlaybackOnLock else { return }

        for screen in screens {
            guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                  config.wallpaperType == .video,
                  config.setAsLockScreen else { continue }
            extractLockScreenFrame(for: screen)
        }
    }
    
    // MARK: - Public Interface
    func reloadWallpaperForScreen(_ screen: Screen) {
        Logger.info("Manually reloading wallpaper for screen \(screen.id)", category: .screenManager)

        guard let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else {
            releaseRuntimeSession(screen)
            return
        }

        primeBookmarkDisplayNames(from: configuration)
        releaseRuntimeSession(screen)
        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }
    
    #if !LITE_BUILD
    // MARK: - Wallpaper Engine Import

    func wpeImportError(for screen: Screen) -> AppError? {
        wpeImportTracker.error(for: screen.id)
    }

    func clearWPEImportError(for screen: Screen) {
        wpeImportTracker.clearError(for: screen.id)
    }

    typealias WPEProjectPreparationOutcome = WPEImportCoordinator.PreparationOutcome
    typealias WPEProjectApplyOutcome = WPEImportCoordinator.ApplyOutcome

    @discardableResult
    func importWallpaperEngineProject(at folderURL: URL, for screen: Screen) async -> WPEProjectApplyOutcome {
        await wpeImportCoordinator.importProject(at: folderURL, for: screen)
    }

    func activateWPEHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async {
        await wpeImportCoordinator.activateHistoryEntry(entry, for: screen)
    }

    func removeWPEImport(workshopID: String) {
        // If a screen is currently rendering the scene being deleted, switch it
        // away FIRST — otherwise its live renderer keeps reading the cache files
        // that the delete is about to move to the Trash. `clearWallpaperOfType`
        // tears down the scene session (synchronously, on every fallback path)
        // and falls back to the screen's saved video/html (or blanks it),
        // persisting the result. Match the active SceneDescriptor — what
        // actually drives the renderer and names the cache dir — not the
        // separate `wpeOrigin` metadata, which can be nil or stale.
        // Match scenes by their live descriptor AND video/web by their persisted
        // `wpeOrigin` — a packaged video/web import renders as `.video`/`.html`,
        // so a scene-only match left it rendering from files about to be deleted.
        let cacheRelativePath = "wpe-cache/\(workshopID)"
        for screen in screens {
            guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { continue }
            let matchesScene: Bool
            if case .scene(let descriptor) = config.activeWallpaper {
                matchesScene = descriptor.workshopID == workshopID || descriptor.cacheRelativePath == cacheRelativePath
            } else {
                matchesScene = false
            }
            guard matchesScene || config.wpeOrigin?.workshopID == workshopID else { continue }
            clearWallpaperOfType(config.activeWallpaper.wallpaperType, for: screen)
        }
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

    func updateVideoColorSpace(_ colorSpace: VideoColorSpace, for screen: Screen) {
        playbackCoordinator.updateVideoColorSpace(colorSpace, for: screen)
    }

    func updateSceneMouseInteraction(_ enabled: Bool, for screen: Screen) {
        playbackCoordinator.updateSceneMouseInteraction(enabled, for: screen)
    }

    func updateSceneClickCapture(_ enabled: Bool, for screen: Screen) {
        playbackCoordinator.updateSceneClickCapture(enabled, for: screen)
    }

    func updateVideoDisplayMode(_ mode: VideoDisplayMode, for screen: Screen) {
        guard var sourceConfiguration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              sourceConfiguration.wallpaperType == .video,
              sourceConfiguration.hasConfiguredVideoSource else { return }

        switch mode {
        case .perDisplay:
            let sourceBookmark = sourceConfiguration.videoBookmarkData
            var changed = false

            for target in screens {
                guard var targetConfiguration = configurationStore.get(for: target.id, fingerprint: target.displayFingerprint),
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

    func updateSceneFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        playbackCoordinator.updateSceneFitMode(fitMode, for: screen)
    }

    func updateFrameRateLimit(_ frameRateLimit: FrameRateLimit, for screen: Screen) {
        playbackCoordinator.updateFrameRateLimit(frameRateLimit, for: screen)
    }

    private func applyFrameRateLimit(_ frameRateLimit: FrameRateLimit, to screen: Screen) {
        playbackCoordinator.applyFrameRateLimit(frameRateLimit, to: screen)
    }
    
    func getConfiguration(for screen: Screen) -> ScreenConfiguration? {
        configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)
    }

    /// Restores per-display playback / effect / audio / layout settings to
    /// their defaults while preserving the wallpaper content itself: video
    /// bookmarks, HTML source, scene/WPE source, playlist bookmarks, and
    /// WPE origin metadata are left intact. The HTML config that travels
    /// with `activeWallpaper` and `savedHTMLConfig` is reset to defaults
    /// since it represents settings, not source content.
    func resetDisplaySettings(for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }

        config.playbackSpeed = 1.0
        config.fitMode = .aspectFill
        config.videoDisplayMode = .perDisplay
        // Match the per-type natural default the constructor uses so
        // "Reset to defaults" on a scene goes to 30 (WPE parity), not 60.
        config.frameRateLimit = FrameRateLimit.naturalDefault(for: config.wallpaperType)
        config.particleEffect = .none
        config.effectConfig = .default
        config.scheduleSlots = nil
        config.shufflePlaylist = false
        config.playlistRotationMinutes = nil
        config.setAsLockScreen = false
        config.wallpaperMode = .playlist
        config.muted = true
        config.videoVolume = 1.0
        config.sceneMouseInteractionEnabled = true
        config.sceneClickCaptureEnabled = false
        config.savedHTMLConfig = .default
        if case .html(let source, _) = config.activeWallpaper {
            config.activeWallpaper = .html(source: source, config: .default)
        }

        releaseRuntimeSession(screen)
        saveConfiguration(config)
        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
        notifyWallpaperSessionChanged()
        Logger.info("Reset display settings for screen \(screen.id)", category: .screenManager)
    }

    /// Copies the active wallpaper + per-screen settings from `source` onto every other registered screen, restoring each runtime session so the new content shows immediately.
    func applyConfigurationToAllDisplays(from source: Screen) {
        guard screens.count > 1,
              let template = configurationStore.get(for: source.id, fingerprint: source.displayFingerprint) else { return }

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
            guard let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else {
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
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.setAsLockScreen != enabled else { return }
        config.setAsLockScreen = enabled
        saveConfiguration(config)
    }

    /// Returns `true` when a frame extraction request was actually issued
    /// (player exists with a `currentItem`). Callers use the result to gate
    /// UI feedback so a silent no-op can't show a false success indicator.
    @discardableResult
    func extractLockScreenFrame(for screen: Screen) -> Bool {
        guard let player = screen.videoPlayer?.player else { return false }

        return DesktopPictureFrameExtractor.applyCurrentFrame(
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
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let previousWallpaper = config.activeWallpaper
        guard config.activateSavedVideoWallpaper() else { return }

        if previousWallpaper == config.activeWallpaper,
           screen.runtimeSession?.wallpaperType == .video {
            Logger.info("Video wallpaper already active for screen \(screen.id); keeping existing player session", category: .screenManager)
            return
        }

        saveConfiguration(config)

        loadConfigurationForScreen(screen)
    }

    /// Restore previously-applied HTML source after the user toggles the type picker back to HTML.
    func switchToHTMLWallpaper(for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
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
        var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .scene(descriptor)
        )
        if configuration.activeWallpaper == .scene(descriptor),
           configuration.wpeOrigin == origin,
           screen.runtimeSession?.wallpaperType == .scene {
            Logger.info("Scene wallpaper already active for screen \(screen.id); keeping existing scene session", category: .screenManager)
            return
        }

        configuration.setSceneWallpaper(descriptor, origin: origin)
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
            let isLeader = htmlCoordinator.isAudioLeader(source: source, excluding: screen.id)
            let effectiveConfig = htmlCoordinator.runtimeConfig(source: source, config: htmlConfig, for: screen)
            session = ambientSessionBuilder.makeHTMLSession(source: source, config: effectiveConfig, frame: screen.frame)
            Logger.info("Set HTML wallpaper for screen \(screen.id) — \(source.displayName) [leader=\(isLeader)]", category: .screenManager)
        case .metalShader(let shaderSource):
            #if !LITE_BUILD
            session = ambientSessionBuilder.makeShaderSession(source: shaderSource, frame: screen.frame)
            Logger.info("Set shader wallpaper (\(shaderSource)) for screen \(screen.id)", category: .screenManager)
            #else
            _ = shaderSource
            return
            #endif
        case .scene(let descriptor):
            #if !LITE_BUILD
            let dependencyMounts = WPEDependencyMountResolver().mounts(
                dependencyWorkshopIDs: descriptor.dependencyWorkshopIDs,
                origin: configuration.wpeOrigin
            )
            let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
            guard let sceneSession = ambientSessionBuilder.makeSceneSession(
                descriptor: descriptor,
                origin: configuration.wpeOrigin,
                frame: screen.frame,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: engineRoot
            ) else {
                Logger.warning("Scene wallpaper for screen \(screen.id) (workshop \(descriptor.workshopID)) could not be built — cache missing or descriptor invalid", category: .screenManager)
                return
            }
            observeRuntimeErrors(for: sceneSession)
            screen.installRuntimeSession(sceneSession)
            refreshAppNapAssertion()
            // Push the persisted playback inspector state into the freshly
            // installed scene session so the user's saved Frame Rate /
            // Mute / Volume take effect from the first frame instead of
            // only after the inspector slider moves. (For mute/volume
            // this is also why those controls used to be dead UI for
            // `.scene` — there was nothing to push them through.)
            sceneSession.frameRateController?.setFrameRateLimit(configuration.frameRateLimit)
            sceneSession.setMouseInteractionEnabled(configuration.sceneMouseInteractionEnabled)
            sceneSession.setClickCaptureEnabled(configuration.sceneClickCaptureEnabled)
            sceneSession.setSceneFitMode(configuration.fitMode)
            if let audio = sceneSession.audioController {
                audio.setAudioMuted(configuration.muted)
                audio.setAudioVolume(configuration.videoVolume)
            }
            applyPerformancePolicy(to: screen)
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
        refreshAppNapAssertion()
        applyPerformancePolicy(to: screen)
        notifyWallpaperSessionChanged()
    }

    // MARK: - HTML Wallpaper (delegates to HTMLWallpaperCoordinator)

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

    /// Replace the active scene's `SceneDescriptor` (currently used by the
    /// Pro inspector to push user-edited `project.json` properties down).
    /// Restarts the wallpaper session so the renderer picks up the new
    /// overrides — there's no in-place apply seam on the WPE runtimes yet,
    /// the way HTML has `applyHTMLConfig`.
    func updateSceneDescriptor(_ descriptor: SceneDescriptor, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        guard case .scene(let current) = configuration.activeWallpaper,
              current.workshopID == descriptor.workshopID else {
            return
        }
        guard current != descriptor else { return }

        #if !LITE_BUILD
        // Fast path: if every changed property is incrementally applicable
        // (e.g. a visibility toggle), patch the live renderer instead of a full
        // reload. Falls through to the reload path when the renderer can't.
        if let sceneSession = screen.runtimeSession as? SceneWallpaperSession {
            let bindings = sceneSession.scenePropertyBindings
            if !bindings.isEmpty {
                let patch = WPEScenePropertyPatch(
                    bindingsByProperty: bindings,
                    oldValues: effectiveSceneValues(for: current, origin: configuration.wpeOrigin),
                    newValues: effectiveSceneValues(for: descriptor, origin: configuration.wpeOrigin)
                )
                if sceneSession.applyScenePropertyPatch(patch) {
                    configuration.activeWallpaper = .scene(descriptor)
                    configuration.savedSceneDescriptor = descriptor
                    saveConfiguration(configuration)
                    notifyWallpaperSessionChanged()
                    return
                }
            }
        }
        #endif

        configuration.activeWallpaper = .scene(descriptor)
        configuration.savedSceneDescriptor = descriptor
        saveConfiguration(configuration)
        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }

    #if !LITE_BUILD
    /// Effective property values (schema defaults merged with the descriptor's
    /// overrides) used to diff old vs new settings for incremental apply.
    /// Package-/source-backed scenes read `project.json` in place from the source
    /// folder (zero-cache); legacy `.cache` scenes read the extracted directory.
    private func effectiveSceneValues(
        for descriptor: SceneDescriptor,
        origin: WPEOrigin?
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        switch descriptor.assetStorage {
        case .cache:
            guard WPEPathSafety.isSafeCacheRelativePath(descriptor.cacheRelativePath),
                  let supportRoot = try? FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                  ).appendingPathComponent("LiveWallpaper", isDirectory: true) else {
                return descriptor.propertyOverrides
            }
            let cacheRoot = supportRoot.appendingPathComponent(descriptor.cacheRelativePath, isDirectory: true)
            if FileManager.default.fileExists(atPath: cacheRoot.path) {
                return WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                    descriptor: descriptor,
                    cacheRootURL: cacheRoot
                )
            }
            // Cache purged but the import source may still be resolvable — read
            // `project.json` in place so property diffing matches the render
            // path's lazy fallback. Falls back to bare overrides otherwise.
            guard let origin,
                  case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                    origin.sourceFolderBookmark, target: .transient
                  ) else {
                return descriptor.propertyOverrides
            }
            return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                    descriptor: descriptor,
                    cacheRootURL: resolved.url
                )
            }
        case .sourceDirectory, .packageSource:
            guard let origin,
                  case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                    origin.sourceFolderBookmark, target: .transient
                  ) else {
                return descriptor.propertyOverrides
            }
            return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                    descriptor: descriptor,
                    cacheRootURL: resolved.url
                )
            }
        }
    }
    #endif

    // MARK: - Metal Shader Wallpaper

    /// Matches `setSceneWallpaper` — the body only touches Core schema +
    /// session restore. The Pro-only `makeShaderSession` call is reached
    /// indirectly through `restoreWallpaperSession → activateAmbientWallpaper`
    /// where the `.metalShader` case is gated with `#if !LITE_BUILD`, so this
    /// stays ungated for Lite-side bookmark restore / decode compatibility.
    func setShaderWallpaper(source: ShaderSource, for screen: Screen) {
        let previousContent = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)?.activeWallpaper
        var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) ?? ScreenConfiguration(
            screenID: screen.id, wallpaper: .metalShader(source)
        )
        config.setShaderWallpaper(source)
        originReconciler.reconcile(
            &config,
            event: .userReplacedActiveWallpaper(previous: previousContent)
        )
        saveConfiguration(config)

        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
    }

    /// Counterpart to `switchToVideoWallpaper` / `switchToHTMLWallpaper` for
    /// the shader tab. Never auto-activates a shader the user didn't pick:
    /// if a shader is already running this is a no-op (idempotent re-entry);
    /// if the active wallpaper is something else (video / html / scene) the
    /// tab swap is honored visually — the shader gallery shows in the
    /// preview area — but no shader runtime spins up until the user clicks
    /// a preset card. Matches the "saved restore" pattern the other tabs
    /// use: silent when there's nothing to restore.
    func switchToShaderWallpaper(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        if case .metalShader = config.activeWallpaper { return }
        // Intentional no-op when active wallpaper is video / html / scene.
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

    func updatePlaylistRotationMinutes(_ minutes: Int?, for screen: Screen) {
        automationOrchestrator.updatePlaylistRotationMinutes(minutes, for: screen)
    }
}
