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

struct ScreenManagerStartupOptions: Equatable {
    var restoreSavedWallpapers: Bool = true
    var startAutomation: Bool = true
    var powerMonitor: (any PowerMonitoring)? = nil
    var fullScreenDetector: (any FullScreenDetecting)? = nil
    var playableVideoLoader: (any PlayableVideoLoading)? = nil
    var displayRegistry: (any DisplayRegistering)? = nil

    // Reference-typed protocol fields are not synthesizable for Equatable.
    // Compare only the value-typed boolean configuration; injected dependencies
    // are test-time concerns and equality is irrelevant for them.
    static func == (lhs: ScreenManagerStartupOptions, rhs: ScreenManagerStartupOptions) -> Bool {
        lhs.restoreSavedWallpapers == rhs.restoreSavedWallpapers
            && lhs.startAutomation == rhs.startAutomation
    }
}

@MainActor @Observable
final class ScreenManager {
    // MARK: - Properties

    private(set) var screens: [Screen] = []
    private(set) var wallpaperSessionStateVersion: UInt64 = 0
    private(set) var wallpaperSessionSummaryCache = WallpaperSessionSummaryCache()
    /// Per-screen WPE import error state. Keying on `CGDirectDisplayID` keeps
    /// concurrent multi-screen imports from overwriting each other's alerts.
    private(set) var lastWPEImportErrors: [CGDirectDisplayID: AppError] = [:]
    private(set) var bookmarkDisplayNames: [Data: String] = [:]

    @ObservationIgnored private var cleanupTasks: Set<AnyCancellable> = []
    @ObservationIgnored private let displayRegistry: any DisplayRegistering
    @ObservationIgnored private let configurationStore = WallpaperConfigurationStore()
    @ObservationIgnored private let ambientSessionBuilder = AmbientWallpaperSessionBuilder()
    @ObservationIgnored private let wpeImportService = WallpaperEngineImportService()
    @ObservationIgnored private let wpeCachedContentResolver = WPECachedContentResolver()
    @ObservationIgnored private let automationCoordinator = WallpaperAutomationCoordinator()
    @ObservationIgnored private let powerPolicy = PowerPolicyController()
    @ObservationIgnored private let powerMonitor: any PowerMonitoring
    @ObservationIgnored private let playbackStateSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored private let fullScreenDetector: any FullScreenDetecting
    @ObservationIgnored private let playableVideoLoader: any PlayableVideoLoading
    @ObservationIgnored private let videoEffectsApplier = VideoEffectsApplicationService()
    @ObservationIgnored private let restoresSavedWallpapersOnScreenRefresh: Bool
    @ObservationIgnored private let exclusiveRenderingCoordinator = ExclusiveRenderingCoordinator()
    @ObservationIgnored private var exclusiveRenderingObservation: NSObjectProtocol?
    @ObservationIgnored private var unresolvedBookmarkDisplayNames: Set<Data> = []
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
            self?.applyVideoEffects(for: screen, config: config)
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
        }
    )
    @ObservationIgnored private var transitionRegistry: PlaybackTransitionRegistry {
        playbackCoordinator.transition
    }
    /// Drops stale async WPE imports per screen (mirrors `transitionRegistry`).
    @ObservationIgnored private var wpeImportGeneration: [CGDirectDisplayID: Int] = [:]
    @ObservationIgnored let weatherService = WeatherReactiveService()
    @ObservationIgnored private lazy var lockScreenSnapshotCoordinator = LockScreenSnapshotCoordinator { [weak self] in
        self?.captureDesktopSnapshotsForLockIfNeeded()
    }
    // MARK: - Initialization
    init(startupOptions: ScreenManagerStartupOptions = ScreenManagerStartupOptions()) {
        displayRegistry = startupOptions.displayRegistry ?? DisplayRegistry()
        powerMonitor = startupOptions.powerMonitor ?? PowerMonitor.shared
        fullScreenDetector = startupOptions.fullScreenDetector ?? FullScreenDetector()
        playableVideoLoader = startupOptions.playableVideoLoader ?? PlayableVideoLoader()
        restoresSavedWallpapersOnScreenRefresh = startupOptions.restoreSavedWallpapers

        Logger.notice("ScreenManager initializing", category: .screenManager)
        setupPowerMonitoring()
        setupScreenObservers()
        setupMemoryMonitoring()
        setupFullScreenDetection()
        setupExclusiveRenderingCoordinator()
        _ = lockScreenSnapshotCoordinator

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
            startScheduleMonitoring()
            startWeatherMonitoring()
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
        let snapshot = exclusiveRenderingCoordinator.isConsoleKeyWindow
        applyConsoleKeyState(isConsoleKey: snapshot)
        withObservationTracking {
            _ = exclusiveRenderingCoordinator.isConsoleKeyWindow
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyConsoleKeyState(isConsoleKey: self.exclusiveRenderingCoordinator.isConsoleKeyWindow)
                self.scheduleConsoleKeyTracking()
            }
        }
    }

    private func applyConsoleKeyState(isConsoleKey: Bool) {
        for screen in screens {
            guard let session = screen.runtimeSession as? SceneWallpaperSession else { continue }
            session.setThrottled(isConsoleKey)
        }
    }

    private func observeFullScreenChanges() {
        withObservationTracking {
            _ = fullScreenDetector.hiddenScreens
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
        configurationStore.remove(for: screen.id)
        postConfigurationDidChange(for: screen.id)
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
        videoEffectsApplier.cancelInflight(for: screen.id)
        transitionRegistry.cancelAssetReadiness(for: screen.id)
        screen.resetRuntimeSession()
        powerPolicy.clearTracking(for: screen.id)
    }

    func resetAllWallpaperSessions() {
        for screen in screens {
            releaseRuntimeSession(screen)
        }
        configurationStore.clearCache()
        notifyWallpaperSessionChanged()
    }
    
    // MARK: - Configuration Management

    /// Light launch-time pass: prunes configurations whose local resource
    /// bookmark is no longer resolvable. Does not tear down healthy sessions.
    func pruneInvalidConfigurationsIfNeeded() {
        let removedScreenIDs = configurationStore.pruneInvalidResourceConfigurations(
            using: SettingsManager.shared.validateConfiguration
        )

        guard !removedScreenIDs.isEmpty else { return }

        for removedScreenID in removedScreenIDs {
            if let screen = screens.first(where: { $0.id == removedScreenID }) {
                Logger.warning("Removing invalid resource configuration for screen \(removedScreenID)", category: .settings)
                releaseRuntimeSession(screen)
            }
        }
        notifyWallpaperSessionChanged()
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
        return screen.runtimeSession?.runtimeError
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
        bookmarkDisplayNames[bookmarkData]
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
        guard !bookmarkData.isEmpty else { return }
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            bookmarkDisplayNames.removeValue(forKey: bookmarkData)
            unresolvedBookmarkDisplayNames.insert(bookmarkData)
            return
        }

        bookmarkDisplayNames[bookmarkData] = trimmed
        unresolvedBookmarkDisplayNames.remove(bookmarkData)
    }

    private func primeBookmarkDisplayNames(from configuration: ScreenConfiguration) {
        for bookmarkData in videoBookmarks(in: configuration) {
            resolveBookmarkDisplayNameIfNeeded(bookmarkData)
        }
    }

    private func resolveBookmarkDisplayNameIfNeeded(_ bookmarkData: Data) {
        guard !bookmarkData.isEmpty,
              bookmarkDisplayNames[bookmarkData] == nil,
              !unresolvedBookmarkDisplayNames.contains(bookmarkData) else { return }
        recordBookmarkDisplayName(
            bookmarkData,
            name: ResourceUtilities.resolveBookmarkName(bookmarkData)
        )
    }

    private func videoBookmarks(in configuration: ScreenConfiguration) -> [Data] {
        var result: [Data] = []
        var seen: Set<Data> = []

        func append(_ bookmarkData: Data?) {
            guard let bookmarkData,
                  !bookmarkData.isEmpty,
                  seen.insert(bookmarkData).inserted else { return }
            result.append(bookmarkData)
        }

        if case .video(let bookmarkData) = configuration.activeWallpaper {
            append(bookmarkData)
        }
        append(configuration.savedVideoBookmarkData)
        configuration.playlistBookmarks?.forEach { append($0) }
        configuration.scheduleSlots?.forEach { append($0.videoBookmarkData) }

        return result
    }

    private func updatePlaybackState() {
        let isAnyPlaying = screens.contains { $0.playbackController?.isPlaying ?? false }

        if playbackStateSubject.value != isAnyPlaying {
            playbackStateSubject.send(isAnyPlaying)
        }
    }

    private func markWallpaperSessionStateChanged() {
        wallpaperSessionStateVersion &+= 1
        refreshWallpaperSessionSummaryCache()
        updatePlaybackState()
    }

    private func notifyWallpaperSessionChanged() {
        wallpaperSessionStateVersion &+= 1
        refreshWallpaperSessionSummaryCache()
        updatePlaybackState()
        updateFullScreenFallbackPolling()
        NotificationCenter.default.post(name: .screensRefreshed, object: nil)
    }

    private func refreshWallpaperSessionSummaryCache() {
        wallpaperSessionSummaryCache = WallpaperSessionSummaryCache(
            entries: screens.map { ($0.id, $0.wallpaperSessionSummary) }
        )
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
    
    // MARK: - Wallpaper Engine Import

    /// Returns the most recent WPE import error for the given screen, or `nil`.
    /// Used by the Scene tab to surface failures without bleeding state across
    /// concurrent imports on different displays.
    func wpeImportError(for screen: Screen) -> AppError? {
        lastWPEImportErrors[screen.id]
    }

    func clearWPEImportError(for screen: Screen) {
        lastWPEImportErrors.removeValue(forKey: screen.id)
    }

    enum WPEProjectPreparationOutcome: Sendable, Equatable {
        case ready(content: WallpaperContent, origin: WPEOrigin)
        case unsupported(origin: WPEOrigin)
        case rejected(reason: String)
    }

    enum WPEProjectApplyOutcome: Sendable, Equatable {
        case applied(origin: WPEOrigin)
        case unsupported(origin: WPEOrigin)
        case rejected(reason: String)
    }

    func prepareWallpaperEngineProject(at folderURL: URL) async -> WPEProjectPreparationOutcome {
        do {
            let result = try await wpeImportService.importProject(folder: folderURL)
            switch result {
            case .ready(let content, let origin):
                return .ready(content: content, origin: origin)
            case .unsupported(let origin):
                return .unsupported(origin: origin)
            case .rejected(let reason):
                return .rejected(reason: reason)
            }
        } catch {
            return .rejected(reason: error.localizedDescription)
        }
    }

    @discardableResult
    func importWallpaperEngineProject(at folderURL: URL, for screen: Screen) async -> WPEProjectApplyOutcome {
        let generation = bumpWPEImportGeneration(for: screen.id)
        let outcome = await prepareWallpaperEngineProject(at: folderURL)
        guard isCurrentWPEImportGeneration(generation, for: screen.id) else {
            return .rejected(reason: "Action superseded")
        }

        switch outcome {
        case .ready(let content, let origin):
            let now = Date()
            applyReadyWPEImport(content, origin: origin, importedAt: now, lastUsedAt: now, for: screen)
            return .applied(origin: origin)

        case .unsupported(let origin):
            // Scene/application/unknown checks are non-destructive: record the
            // origin and let UI show a reason card instead of replacing wallpaper.
            SettingsManager.shared.recordWPEImport(
                WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil)
            )
            postWPEImportDidComplete(
                screenID: screen.id,
                type: origin.originalType,
                workshopID: origin.workshopID
            )
            lastWPEImportErrors.removeValue(forKey: screen.id)
            return .unsupported(origin: origin)

        case .rejected(let reason):
            lastWPEImportErrors[screen.id] = .wpePackageInvalid(reason)
            return .rejected(reason: reason)
        }
    }

    func activateWPEHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async {
        do {
            var isStale = false
            let folderURL = try URL(
                resolvingBookmarkData: entry.origin.sourceFolderBookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let didStartScope = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didStartScope {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            guard didStartScope || FileManager.default.fileExists(atPath: folderURL.path) else {
                if applyCachedWPEHistoryEntry(entry, for: screen) {
                    return
                }
                lastWPEImportErrors[screen.id] = .fileAccessDenied(entry.origin.title)
                return
            }

            lastWPEImportErrors.removeValue(forKey: screen.id)
            await importWallpaperEngineProject(at: folderURL, for: screen)
            if lastWPEImportErrors[screen.id] != nil {
                _ = applyCachedWPEHistoryEntry(entry, for: screen)
            }
        } catch {
            if applyCachedWPEHistoryEntry(entry, for: screen) {
                return
            }
            lastWPEImportErrors[screen.id] = .wpeImportFailed(error.localizedDescription)
        }
    }

    func removeWPEImport(workshopID: String) {
        SettingsManager.shared.removeWPEImport(workshopID: workshopID)

        for var config in configurationStore.loadAll() where config.wpeOrigin?.workshopID == workshopID {
            config.wpeOrigin = nil
            saveConfiguration(config)
        }
    }

    private func postWPEImportDidComplete(
        screenID: CGDirectDisplayID,
        type: WPEType,
        workshopID: String
    ) {
        NotificationCenter.default.post(
            name: .wpeImportDidComplete,
            object: nil,
            userInfo: [
                "screenID": screenID,
                "type": type.rawValue,
                "workshopID": workshopID,
            ]
        )
    }

    private func applyReadyWPEImport(
        _ content: WallpaperContent,
        origin: WPEOrigin,
        importedAt: Date,
        lastUsedAt: Date?,
        for screen: Screen
    ) {
        SettingsManager.shared.recordWPEImport(
            WPEHistoryEntry(origin: origin, importedAt: importedAt, lastUsedAt: lastUsedAt)
        )

        var config = configurationStore.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: content
        )
        config.activeWallpaper = content
        if case .html(let source, let htmlConfig) = content {
            config.savedHTMLSource = source
            config.savedHTMLConfig = htmlConfig
        } else if case .video(let bookmarkData) = content {
            config.savedVideoBookmarkData = bookmarkData
        }
        config.wpeOrigin = origin
        saveConfiguration(config)
        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
        postWPEImportDidComplete(
            screenID: screen.id,
            type: origin.originalType,
            workshopID: origin.workshopID
        )
        lastWPEImportErrors.removeValue(forKey: screen.id)
    }

    @discardableResult
    private func applyCachedWPEHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) -> Bool {
        guard let content = wpeCachedContentResolver.content(for: entry.origin) else {
            return false
        }
        applyReadyWPEImport(
            content,
            origin: entry.origin,
            importedAt: entry.importedAt,
            lastUsedAt: Date(),
            for: screen
        )
        return true
    }

    private func bumpWPEImportGeneration(for screenID: CGDirectDisplayID) -> Int {
        let next = (wpeImportGeneration[screenID] ?? 0) &+ 1
        wpeImportGeneration[screenID] = next
        return next
    }

    private func isCurrentWPEImportGeneration(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool {
        wpeImportGeneration[screenID] == generation
    }

    // MARK: - Configuration Update Helpers

    private func saveConfiguration(_ configuration: ScreenConfiguration) {
        primeBookmarkDisplayNames(from: configuration)
        configurationStore.save(configuration)
        postConfigurationDidChange(for: configuration.screenID)
    }

    private func postConfigurationDidChange(for screenID: CGDirectDisplayID) {
        NotificationCenter.default.post(
            name: .wallpaperConfigurationDidChange,
            object: nil,
            userInfo: ["screenID": screenID]
        )
    }

    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        playbackCoordinator.updatePlaybackSpeed(speed, for: screen)
    }

    func updateMuted(_ muted: Bool, for screen: Screen) {
        playbackCoordinator.updateMuted(muted, for: screen)
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
        let screenIDs = configurationStore.allScreenIDs()
        var validConfigCount = 0
        var invalidConfigCount = 0
        
        for screenID in screenIDs {
            if SettingsManager.shared.validateConfiguration(for: screenID) {
                validConfigCount += 1
            } else {
                invalidConfigCount += 1
                Logger.warning("Invalid configuration found for screen \(screenID)", category: .settings)
            }
        }
        
        Logger.info("Configuration validation complete: \(validConfigCount) valid, \(invalidConfigCount) invalid", category: .settings)
        return (validConfigCount, invalidConfigCount)
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

    // MARK: - Video Effects

    func updateEffectConfig(_ effectConfig: VideoEffectConfig, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        config.effectConfig = effectConfig
        saveConfiguration(config)
        applyVideoEffects(for: screen, config: config)
    }

    func updateParticleEffect(_ effect: ParticleEffect, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        config.particleEffect = effect
        saveConfiguration(config)
        applyParticleEffect(effect, density: config.effectConfig.particleDensity, to: screen)
    }

    func updateParticleDensity(_ density: Double, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        let clamped = min(max(density, 0.2), 3.0)
        guard abs(clamped - config.effectConfig.particleDensity) > 0.001 else { return }
        config.effectConfig.particleDensity = clamped
        saveConfiguration(config)
        screen.videoPlayer?.setParticleDensity(clamped)
    }

    private func applyParticleEffect(_ effect: ParticleEffect, density: Double, to screen: Screen) {
        screen.videoPlayer?.setParticleEffect(effect, density: density)
    }

    // MARK: - Weather-Reactive Effects

    func setWeatherReactive(_ enabled: Bool, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        config.effectConfig.weatherReactive = enabled
        saveConfiguration(config)
        refreshWeatherMonitoringState()

        if enabled {
            applyWeatherEffects(for: screen)
        } else {
            applyParticleEffect(config.particleEffect, density: config.effectConfig.particleDensity, to: screen)
            applyVideoEffects(for: screen, config: config)
        }
    }

    func applyWeatherEffects(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id),
              config.effectConfig.weatherReactive else { return }

        applyParticleEffect(
            weatherService.currentParticleEffect,
            density: config.effectConfig.particleDensity,
            to: screen
        )

        let adj = weatherService.currentEffectAdjustments
        var weatherConfig = config.effectConfig
        weatherConfig.saturation = adj.saturation
        weatherConfig.brightness = adj.brightness
        weatherConfig.warmth = adj.warmth
        weatherConfig.blurRadius = adj.blurRadius
        weatherConfig.vignetteIntensity = adj.vignetteIntensity

        var updatedConfig = config
        updatedConfig.effectConfig = weatherConfig
        applyVideoEffects(for: screen, config: updatedConfig)
    }

    func startWeatherMonitoring() {
        observeWeatherChanges()
        refreshWeatherMonitoringState()
    }

    private func refreshWeatherMonitoringState() {
        let activeScreenIDs = Set(screens.map(\.id))
        let configurations = activeScreenIDs.compactMap { configurationStore.get(for: $0) }
        if WeatherReactivePolicy.shouldMonitor(configurations: configurations, activeScreenIDs: activeScreenIDs) {
            weatherService.startMonitoring()
        } else {
            weatherService.stopMonitoring()
        }
    }

    private func observeWeatherChanges() {
        withObservationTracking {
            _ = weatherService.currentParticleEffect
            _ = weatherService.currentEffectAdjustments
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for screen in self.screens {
                    guard let config = self.configurationStore.get(for: screen.id),
                          config.effectConfig.weatherReactive else { continue }
                    self.applyWeatherEffects(for: screen)
                }
                self.observeWeatherChanges()
            }
        }
    }

    private func applyVideoEffects(for screen: Screen, config: ScreenConfiguration) {
        guard let player = screen.videoPlayer else {
            Logger.warning("Cannot apply effects: no active player for screen \(screen.id)", category: .videoPlayer)
            return
        }

        videoEffectsApplier.applyEffects(
            to: player,
            screenID: screen.id,
            config: config,
            screenRefreshRate: getScreenRefreshRate(for: screen.id),
            noEffectsHandler: { [weak self, weak screen] in
                guard let screen else { return }
                self?.applyFrameRateLimit(config.frameRateLimit, to: screen)
            }
        )
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
            let isLeader = isAudioLeaderForHTML(source: source, excluding: screen.id)
            let effectiveConfig = runtimeHTMLConfig(source: source, config: htmlConfig, for: screen)
            session = ambientSessionBuilder.makeHTMLSession(source: source, config: effectiveConfig, frame: screen.frame)
            Logger.info("Set HTML wallpaper for screen \(screen.id) — \(source.displayName) [leader=\(isLeader)]", category: .screenManager)
        case .metalShader(let preset):
            session = ambientSessionBuilder.makeShaderSession(preset: preset, frame: screen.frame)
            Logger.info("Set shader wallpaper (\(preset.rawValue)) for screen \(screen.id)", category: .screenManager)
        case .scene(let descriptor):
            let dependencyMounts = WPEDependencyMountResolver().mounts(
                dependencyWorkshopIDs: descriptor.dependencyWorkshopIDs,
                origin: configuration.wpeOrigin
            )
            guard let sceneSession = ambientSessionBuilder.makeSceneSession(
                descriptor: descriptor,
                frame: screen.frame,
                dependencyMounts: dependencyMounts
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

    // MARK: - HTML Multi-Instance Diagnostics

    /// Maps each currently-active HTML source signature to the screens that
    /// run it. Inspector uses this to surface "also active on N other screen(s)"
    /// when the user is configuring a wallpaper that's already in use elsewhere.
    func htmlSourceMultiplicity() -> [String: [CGDirectDisplayID]] {
        var map: [String: [CGDirectDisplayID]] = [:]
        for screen in screens {
            guard screen.runtimeSession?.wallpaperType == .html,
                  let config = configurationStore.get(for: screen.id),
                  case .html(let source, _) = config.activeWallpaper else { continue }
            map[source.diagnosticSignature, default: []].append(screen.id)
        }
        return map
    }

    /// Screens (other than `excluding`) currently running the same HTML source.
    func screensRunningSameHTMLSource(as source: HTMLSource, excluding: CGDirectDisplayID) -> [Screen] {
        let signature = source.diagnosticSignature
        return screens.filter { other in
            other.id != excluding
                && other.runtimeSession?.wallpaperType == .html
                && (configurationStore.get(for: other.id)?.activeWallpaper).flatMap { content -> String? in
                    if case .html(let s, _) = content { return s.diagnosticSignature }
                    return nil
                } == signature
        }
    }

    /// True when no other screen is already playing this HTML source — the
    /// caller becomes the audio leader.
    private func isAudioLeaderForHTML(source: HTMLSource, excluding screenID: CGDirectDisplayID) -> Bool {
        screensRunningSameHTMLSource(as: source, excluding: screenID).isEmpty
    }

    private func runtimeHTMLConfig(source: HTMLSource, config: HTMLConfig, for screen: Screen) -> HTMLConfig {
        var effectiveConfig = config

        if !isAudioLeaderForHTML(source: source, excluding: screen.id), !effectiveConfig.muteAudio {
            effectiveConfig.muteAudio = true
            Logger.info("Multi-instance HTML wallpaper: muting screen \(screen.id) (audio leader is another screen running same source)", category: .screenManager)
        }

        let trust = HTMLTrust.evaluate(source: source, trustedOrigins: TrustedHostStore.shared.originSet)
        effectiveConfig.allowJavaScript = trust.effectiveAllowJavaScript(requested: config.allowJavaScript)
        return effectiveConfig
    }

    // MARK: - HTML Wallpaper

    func setHTMLWallpaper(source: HTMLSource, config: HTMLConfig = .default, forceReload: Bool = false, for screen: Screen) {
        var configuration = configurationStore.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .html(source: source, config: config)
        )
        if !forceReload,
           case .html(let existingSource, let existingConfig) = configuration.activeWallpaper,
           existingSource == source,
           existingConfig == config,
           screen.runtimeSession?.wallpaperType == .html {
            Logger.info("HTML wallpaper unchanged for screen \(screen.id); keeping existing WKWebView session", category: .screenManager)
            return
        }

        configuration.setHTMLWallpaper(source: source, config: config)
        configuration.reconcileWPEOrigin()
        saveConfiguration(configuration)

        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }

    /// Swaps HTML source while keeping existing HTML settings.
    func setHTMLWallpaperPreservingConfig(source: HTMLSource, for screen: Screen) {
        let preserved = configurationStore.get(for: screen.id)?.htmlConfig ?? .default
        setHTMLWallpaper(source: source, config: preserved, for: screen)
    }

    func setHTMLWallpaper(url: String, for screen: Screen) {
        guard let source = HTMLSource(userInput: url) else { return }
        setHTMLWallpaper(source: source, for: screen)
    }

    func updateHTMLConfig(_ config: HTMLConfig, for screen: Screen) {
        guard var existing = configurationStore.get(for: screen.id),
              case .html(let source, let previousConfig) = existing.activeWallpaper else { return }
        existing.activeWallpaper = .html(source: source, config: config)
        saveConfiguration(existing)

        let runtimeConfig = runtimeHTMLConfig(source: source, config: config, for: screen)
        if !requiresHTMLSessionRebuild(previous: previousConfig, current: config),
           let applier = screen.runtimeSession as? any HTMLWallpaperConfigApplying,
           applier.applyHTMLConfig(runtimeConfig) {
            if let window = screen.activeWallpaperWindow as? VideoWallpaperWindow {
                window.setWallpaperMouseInteractionEnabled(config.allowMouseInteraction)
            }
            notifyWallpaperSessionChanged()
            return
        }

        restoreWallpaperSession(for: screen, configuration: existing, preservingState: false)
    }

    private func requiresHTMLSessionRebuild(previous: HTMLConfig, current: HTMLConfig) -> Bool {
        previous.useEphemeralStorage != current.useEphemeralStorage
            || previous.allowJavaScript != current.allowJavaScript
            || previous.blockTrackers != current.blockTrackers
    }

    // MARK: - Metal Shader Wallpaper

    func setShaderWallpaper(preset: MetalShaderPreset, for screen: Screen) {
        var config = configurationStore.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id, wallpaper: .metalShader(preset)
        )
        config.setShaderWallpaper(preset)
        config.reconcileWPEOrigin()
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
    
    // MARK: - Playlist Management

    func updatePlaylistBookmarks(_ bookmarks: [Data], for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        config.playlistBookmarks = bookmarks.isEmpty ? nil : bookmarks
        saveConfiguration(config)
    }

    func setPrimaryVideo(bookmark: Data, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id),
              config.savedVideoBookmarkData != bookmark else { return }

        var extras = config.playlistBookmarks ?? []
        if let oldPrimary = config.savedVideoBookmarkData,
           !extras.contains(oldPrimary), oldPrimary != bookmark {
            extras.append(oldPrimary)
        }
        extras.removeAll(where: { $0 == bookmark })

        config.replacePrimaryVideo(bookmarkData: bookmark)
        config.playlistBookmarks = extras.isEmpty ? nil : extras
        saveConfiguration(config)

        reloadWallpaperForScreen(screen)
    }

    /// Writes reordered playlist entries while preserving the active bookmark.
    func replacePlaylist(primary: Data, extras: [Data], for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }

        let oldCombined = [config.savedVideoBookmarkData].compactMap { $0 } + (config.playlistBookmarks ?? [])
        let oldCursor = config.playlistCursorIndex ?? 0
        let oldActive: Data? = oldCursor < oldCombined.count ? oldCombined[oldCursor] : config.videoBookmarkData

        let primaryChanged = config.savedVideoBookmarkData != primary
        config.savedVideoBookmarkData = primary
        config.playlistBookmarks = extras.isEmpty ? nil : extras

        let newCombined = [primary] + extras
        if primaryChanged {
            config.playlistCursorIndex = 0
            config.activeWallpaper = .video(bookmarkData: primary)
        } else {
            let resolved = PlaylistPolicy.resolveCursor(activeBookmark: oldActive, in: newCombined)
            config.playlistCursorIndex = resolved
            if resolved < newCombined.count {
                config.activeWallpaper = .video(bookmarkData: newCombined[resolved])
            }
        }
        saveConfiguration(config)

        if primaryChanged {
            reloadWallpaperForScreen(screen)
        }
    }

    func playPlaylistEntry(at index: Int, for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id),
              let primary = config.savedVideoBookmarkData else { return }
        let combined = [primary] + (config.playlistBookmarks ?? [])
        guard index >= 0, index < combined.count else { return }
        applyPlaylistCursor(index, combined: combined, screen: screen, label: "jumping")
    }

    func updateShufflePlaylist(_ shuffle: Bool, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        config.shufflePlaylist = shuffle
        saveConfiguration(config)
    }

    func advancePlaylist(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id),
              config.wallpaperMode == .playlist,
              let primary = config.savedVideoBookmarkData else { return }

        let combined = [primary] + (config.playlistBookmarks ?? [])
        guard combined.count > 1 else { return }

        let currentCursor = config.playlistCursorIndex ?? 0
        guard let nextCursor = PlaylistPolicy.nextCursor(
            currentCursor: currentCursor,
            playlistCount: combined.count,
            shuffle: config.shufflePlaylist
        ) else { return }

        applyPlaylistCursor(nextCursor, combined: combined, screen: screen, label: "advancing")
    }

    func regressPlaylist(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id),
              config.wallpaperMode == .playlist,
              let primary = config.savedVideoBookmarkData else { return }

        let combined = [primary] + (config.playlistBookmarks ?? [])
        guard combined.count > 1 else { return }

        let currentCursor = config.playlistCursorIndex ?? 0
        guard let prevCursor = PlaylistPolicy.previousCursor(
            currentCursor: currentCursor,
            playlistCount: combined.count,
            shuffle: config.shufflePlaylist
        ) else { return }

        applyPlaylistCursor(prevCursor, combined: combined, screen: screen, label: "regressing")
    }

    func replaceActiveBookmark(_ bookmarkData: Data, for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id) else { return }
        let updated = config.withUpdatedActiveBookmark(bookmarkData)
        saveConfiguration(updated)
    }

    func updateWallpaperMode(_ mode: WallpaperMode, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id),
              config.wallpaperMode != mode else { return }
        config.wallpaperMode = mode
        saveConfiguration(config)
    }

    private func applyPlaylistCursor(
        _ cursor: Int,
        combined: [Data],
        screen: Screen,
        label: String
    ) {
        guard cursor < combined.count else { return }
        let targetBookmark = combined[cursor]

        guard let url = try? ResourceUtilities.resolveBookmark(targetBookmark).url else { return }
        recordBookmarkDisplayName(targetBookmark, name: url.lastPathComponent)

        let screenID = screen.id
        let generation = bumpTransition(for: screenID)
        let videoLoader = playableVideoLoader

        Task { [weak self] in
            do {
                try await videoLoader.validatePlayableVideo(at: url)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.isCurrentTransition(generation, for: screenID),
                          let liveScreen = self.screens.first(where: { $0.id == screenID }),
                          var liveConfig = self.configurationStore.get(for: screenID) else { return }
                    liveConfig.playlistCursorIndex = cursor
                    liveConfig.activeWallpaper = .video(bookmarkData: targetBookmark)
                    self.saveConfiguration(liveConfig)
                    Logger.info("Playlist: \(label) to \(url.lastPathComponent) (cursor \(cursor)) for screen \(screenID)", category: .screenManager)
                    self.releaseRuntimeSession(liveScreen)
                    self.setupVideoPlayback(url: url, screen: liveScreen)
                }
            } catch {
                Logger.error("Playlist \(label) failed for screen \(screenID): \(error.localizedDescription)", category: .screenManager)
            }
        }
    }

    // MARK: - Schedule Management

    func updateScheduleSlots(_ slots: [ScheduleSlot]?, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        config.scheduleSlots = slots
        saveConfiguration(config)

        if slots != nil {
            checkAndApplySchedule(for: screen)
        }
    }

    func checkAndApplySchedule(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id) else { return }

        let currentHour = Calendar.current.component(.hour, from: Date())

        switch SchedulePolicy.decision(for: config, hour: currentHour) {
        case .none:
            return

        case .applySlot(let slot, let bookmark):
            performScheduledSwitch(
                bookmark: bookmark,
                logLabel: "switching to \(slot.label) wallpaper",
                for: screen
            ) { config in
                config.applyScheduledBookmark(bookmark)
            }

        case .restorePrimary(let bookmark):
            performScheduledSwitch(
                bookmark: bookmark,
                logLabel: "slot window ended, restoring primary",
                for: screen
            ) { config in
                _ = config.activateSavedVideoWallpaper()
            }
        }
    }

    private func performScheduledSwitch(
        bookmark: Data,
        logLabel: String,
        for screen: Screen,
        mutate: @escaping (inout ScreenConfiguration) -> Void
    ) {
        guard let url = try? ResourceUtilities.resolveBookmark(bookmark).url else { return }
        recordBookmarkDisplayName(bookmark, name: url.lastPathComponent)

        let screenID = screen.id
        let generation = bumpTransition(for: screenID)
        let videoLoader = playableVideoLoader

        Task { [weak self] in
            do {
                try await videoLoader.validatePlayableVideo(at: url)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.isCurrentTransition(generation, for: screenID),
                          let liveScreen = self.screens.first(where: { $0.id == screenID }),
                          var liveConfig = self.configurationStore.get(for: screenID) else { return }
                    Logger.info("Schedule: \(logLabel) for screen \(screenID)", category: .screenManager)
                    mutate(&liveConfig)
                    self.saveConfiguration(liveConfig)
                    self.releaseRuntimeSession(liveScreen)
                    self.setupVideoPlayback(url: url, screen: liveScreen)
                }
            } catch {
                Logger.error("Schedule transition failed for screen \(screenID): \(error.localizedDescription)", category: .screenManager)
            }
        }
    }

    private func startScheduleMonitoring() {
        automationCoordinator.start(
            screenProvider: { [weak self] in
                self?.screens ?? []
            },
            configurationProvider: { [weak self] screenID in
                self?.configurationStore.get(for: screenID)
            },
            scheduleHandler: { [weak self] screen in
                self?.checkAndApplySchedule(for: screen)
            },
            playlistHandler: { [weak self] screen in
                self?.advancePlaylist(for: screen)
            }
        )
    }

    func updatePlaylistRotationMinutes(_ minutes: Int?, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        config.playlistRotationMinutes = minutes
        saveConfiguration(config)
    }
}
