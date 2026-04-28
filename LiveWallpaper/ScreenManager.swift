import SwiftUI
import Combine
import Observation

private final class WallpaperAssetReadinessWork {
    var frameRateSubscription: AnyCancellable?
    var fallbackTask: Task<Void, Never>?

    func cancel() {
        frameRateSubscription?.cancel()
        frameRateSubscription = nil
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    deinit {
        cancel()
    }
}

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
}

@MainActor @Observable
final class ScreenManager {
    // MARK: - Properties

    private(set) var screens: [Screen] = []
    private(set) var wallpaperSessionStateVersion: UInt64 = 0
    private(set) var wallpaperSessionSummaryCache = WallpaperSessionSummaryCache()

    @ObservationIgnored private var cleanupTasks: Set<AnyCancellable> = []
    @ObservationIgnored private let displayRegistry = DisplayRegistry()
    @ObservationIgnored private let configurationStore = WallpaperConfigurationStore()
    @ObservationIgnored private let ambientSessionBuilder = AmbientWallpaperSessionBuilder()
    @ObservationIgnored private let automationCoordinator = WallpaperAutomationCoordinator()
    @ObservationIgnored private let powerPolicy = PowerPolicyController()
    @ObservationIgnored private let powerMonitor: PowerMonitor = .shared
    @ObservationIgnored private let playbackStateSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored private let fullScreenDetector = FullScreenDetector()
    @ObservationIgnored private let videoEffectsApplier = VideoEffectsApplicationService()
    @ObservationIgnored private let restoresSavedWallpapersOnScreenRefresh: Bool
    /// Drops stale async video transitions.
    @ObservationIgnored private var transitionGeneration: [CGDirectDisplayID: Int] = [:]
    @ObservationIgnored private var assetReadinessWork: [CGDirectDisplayID: WallpaperAssetReadinessWork] = [:]
    @ObservationIgnored let weatherService = WeatherReactiveService()
    @ObservationIgnored private lazy var lockScreenSnapshotCoordinator = LockScreenSnapshotCoordinator { [weak self] in
        self?.captureDesktopSnapshotsForLockIfNeeded()
    }
    // MARK: - Initialization
    init(startupOptions: ScreenManagerStartupOptions = ScreenManagerStartupOptions()) {
        restoresSavedWallpapersOnScreenRefresh = startupOptions.restoreSavedWallpapers

        Logger.notice("ScreenManager initializing", category: .screenManager)
        setupPowerMonitoring()
        setupScreenObservers()
        setupMemoryMonitoring()
        setupFullScreenDetection()
        _ = lockScreenSnapshotCoordinator

        NotificationCenter.default.publisher(for: WallpaperVideoPlayer.didChangePlaybackStateNotification)
            .sink { [weak self] _ in
                self?.markWallpaperSessionStateChanged()
            }
            .store(in: &cleanupTasks)

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
        
        NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)
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
        videoEffectsApplier.cancelInflight(for: screen.id)
        assetReadinessWork[screen.id]?.cancel()
        assetReadinessWork[screen.id] = nil
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
    private func loadConfigurationForScreen(_ screen: Screen) {
        // If screen already has a video player, just update settings
        if screen.videoPlayer != nil {
            if let cachedConfig = configurationStore.get(for: screen.id) {
                // Apply configuration without recreating the player
                applyConfiguration(cachedConfig, to: screen, preservingState: true)
            }
            return
        }

        guard let config = configurationStore.get(for: screen.id) else { return }
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
            activateAmbientWallpaper(.html(source, htmlConfig), for: screen)
        case .metalShader(let preset):
            activateAmbientWallpaper(.metalShader(preset), for: screen)
        }
    }
    
    // MARK: - Video Management

    /// Replaces the primary video while preserving per-screen settings.
    func setVideo(url: URL, bookmarkData: Data, for screen: Screen) {
        Logger.info("Setting video for screen \(screen.id): \(url.lastPathComponent)", category: .screenManager)

        let existing = configurationStore.get(for: screen.id)

        let isSameURL: Bool = {
            guard let existingBookmark = existing?.videoBookmarkData else { return false }
            var isStale = false
            let resolved = try? URL(
                resolvingBookmarkData: existingBookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return resolved == url
        }()

        var configuration: ScreenConfiguration
        if var prior = existing {
            prior.replacePrimaryVideo(bookmarkData: bookmarkData)
            configuration = prior
        } else {
            configuration = ScreenConfiguration(
                screenID: screen.id,
                videoBookmarkData: bookmarkData
            )
        }
        if isSameURL, screen.videoPlayer != nil {
            configurationStore.save(configuration)
            applyConfiguration(configuration, to: screen, preservingState: true)
            return
        }

        let generation = bumpTransition(for: screen.id)
        Task {
            do {
                try await PlayableVideoLoader.validatePlayableVideo(at: url)
                await MainActor.run { [weak self] in
                    guard let self, self.isCurrentTransition(generation, for: screen.id) else { return }
                    self.configurationStore.save(configuration)
                    guard SettingsManager.shared.validateConfiguration(for: screen.id) else {
                        Logger.error("Failed to save video configuration for screen \(screen.id)", category: .screenManager)
                        if let existing {
                            self.configurationStore.save(existing)
                        } else {
                            self.configurationStore.remove(for: screen.id)
                        }
                        return
                    }
                    self.setupVideoPlayback(url: url, screen: screen)
                }
            } catch {
                await MainActor.run {
                    Logger.error("Failed to setup video: \(error.localizedDescription)", category: .screenManager)
                }
            }
        }
    }

    private func bumpTransition(for screenID: CGDirectDisplayID) -> Int {
        let next = (transitionGeneration[screenID] ?? 0) &+ 1
        transitionGeneration[screenID] = next
        return next
    }

    private func isCurrentTransition(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool {
        transitionGeneration[screenID] == generation
    }

    private func applyConfiguration(_ configuration: ScreenConfiguration, to screen: Screen, preservingState: Bool = false) {
        do {
            guard let bookmarkData = configuration.videoBookmarkData else {
                throw NSError(domain: "ScreenManager", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "No saved video bookmark is available for this screen."
                ])
            }

            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            guard url.startAccessingSecurityScopedResource() else {
                throw NSError(domain: "ScreenManager", code: 403, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot access the video file. Permission denied."
                ])
            }
            
            defer {
                url.stopAccessingSecurityScopedResource()
            }
            
            if isStale {
                do {
                    let updatedBookmarkData = try url.bookmarkData(
                        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    let updatedConfig = configuration.withUpdatedActiveBookmark(updatedBookmarkData)
                    saveConfiguration(updatedConfig)
                } catch {
                    Logger.error("Failed to update stale bookmark: \(error.localizedDescription)", category: .fileAccess)
                }
            }
            
            let needsNewPlayer = screen.videoPlayer == nil
            
            if !needsNewPlayer {
                let currentTime = preservingState ? screen.videoPlayer?.player?.currentTime() : .zero
                let wasPlaying = screen.videoPlayer?.isPlaying ?? false
                
                if let player = screen.videoPlayer {
                    player.setVideoFitMode(configuration.fitMode)
                    
                    let currentSpeed = player.player?.defaultRate ?? 1.0
                    if abs(Float(configuration.playbackSpeed) - currentSpeed) > 0.01 {
                        player.setPlaybackSpeed(configuration.playbackSpeed)
                    }
                    
                    if player.videoFrameRate > 0 {
                        if configuration.effectConfig.hasActiveEffect {
                            applyVideoEffects(for: screen, config: configuration)
                        } else {
                            applyFrameRateLimit(configuration.frameRateLimit, to: screen)
                        }
                    }
                    
                    if let currentTime = currentTime {
                        player.player?.seek(to: currentTime)
                    }
                    
                    let globalSettings = SettingsManager.shared.loadGlobalSettings()
                    let shouldPause = WallpaperPolicyEngine.shouldStartVideoPaused(
                        globalSettings: globalSettings,
                        powerSource: powerMonitor.currentPowerSource,
                        isHiddenByFullScreen: fullScreenDetector.isDesktopHidden(for: screen.id)
                    )

                    if shouldPause {
                        player.pause()
                    } else if !wasPlaying {
                        schedulePolicyAwarePlaybackStart(to: player, screenID: screen.id)
                    }
                }
            } else {
                let player = WallpaperVideoPlayer(
                    url: url,
                    frame: screen.frame,
                    fitMode: configuration.fitMode
                )
                screen.installRuntimeSession(VideoWallpaperSession(player: player))
                notifyWallpaperSessionChanged()

                player.setPlaybackSpeed(configuration.playbackSpeed)

                applyConfigurationWhenAssetReady(player: player, screen: screen, configuration: configuration)

                applyStartupPlaybackPolicy(to: player, for: screen)
            }

            let globalSettings = SettingsManager.shared.loadGlobalSettings()
            applyPerformancePolicy(
                to: screen,
                globalSettings: globalSettings,
                powerSource: powerMonitor.currentPowerSource,
                isHiddenByFullScreen: globalSettings.pauseOnFullScreen &&
                    fullScreenDetector.isDesktopHidden(for: screen.id)
            )

        } catch let error as NSError {
            Logger.error("Failed to apply configuration: \(error.localizedDescription) [domain=\(error.domain) code=\(error.code)]", category: .screenManager)
            // Malformed persisted bookmark; clear it to avoid retry loops.
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadCorruptFileError {
                Logger.warning("Clearing unresolvable bookmark for screen \(screen.id); user must re-pick the source.", category: .screenManager)
                configurationStore.remove(for: screen.id)
                releaseRuntimeSession(screen)
                notifyWallpaperSessionChanged()
            }
        } catch {
            Logger.error("Failed to apply configuration: \(error.localizedDescription)", category: .screenManager)
        }
    }
    
    private func applyConfigurationWhenAssetReady(
        player: WallpaperVideoPlayer,
        screen: Screen,
        configuration: ScreenConfiguration
    ) {
        let screenID = screen.id
        assetReadinessWork[screenID]?.cancel()
        assetReadinessWork[screenID] = nil

        let apply: @MainActor () -> Void = { [weak self] in
            guard let self,
                  let liveScreen = self.screens.first(where: { $0.id == screenID }) else { return }
            if configuration.particleEffect != .none {
                player.setParticleEffect(
                    configuration.particleEffect,
                    density: configuration.effectConfig.particleDensity
                )
            }
            if configuration.effectConfig.hasActiveEffect {
                self.applyVideoEffects(for: liveScreen, config: configuration)
            } else {
                self.applyFrameRateLimit(configuration.frameRateLimit, to: liveScreen)
            }
        }

        if player.videoFrameRate > 0 {
            apply()
            return
        }

        let work = WallpaperAssetReadinessWork()
        assetReadinessWork[screenID] = work
        var didApply = false

        let finish: @MainActor () -> Void = { [weak self, weak work] in
            guard let self, !didApply else { return }
            didApply = true
            apply()
            work?.cancel()
            if self.assetReadinessWork[screenID] === work {
                self.assetReadinessWork[screenID] = nil
            }
        }

        work.frameRateSubscription = player.$videoFrameRate
            .first(where: { $0 > 0 })
            .receive(on: DispatchQueue.main)
            .sink { _ in
                finish()
            }

        work.fallbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            finish()
        }
    }

    private func setupVideoPlayback(url: URL, screen: Screen) {
        releaseRuntimeSession(screen)

        let configuration = configurationStore.get(for: screen.id)
        let player = WallpaperVideoPlayer(
            url: url,
            frame: screen.frame,
            fitMode: configuration?.fitMode ?? .aspectFill
        )

        if let stored = configuration?.muted {
            player.setMuted(stored)
        }

        if let index = screens.firstIndex(where: { $0.id == screen.id }) {
            screens[index].installRuntimeSession(VideoWallpaperSession(player: player))
            let liveScreen = screens[index]
            let globalSettings = SettingsManager.shared.loadGlobalSettings()
            applyPerformancePolicy(
                to: liveScreen,
                globalSettings: globalSettings,
                powerSource: powerMonitor.currentPowerSource,
                isHiddenByFullScreen: globalSettings.pauseOnFullScreen &&
                    fullScreenDetector.isDesktopHidden(for: liveScreen.id)
            )

            if let configuration {
                player.setPlaybackSpeed(configuration.playbackSpeed)
                applyConfigurationWhenAssetReady(player: player, screen: liveScreen, configuration: configuration)
            }

            applyStartupPlaybackPolicy(to: player, for: liveScreen)

            Logger.info("Video player setup complete for screen \(screen.id)", category: .screenManager)
            notifyWallpaperSessionChanged()
        } else {
            Logger.warning("Screen with ID \(screen.id) not found in screens array", category: .screenManager)
        }
    }

    private func applyStartupPlaybackPolicy(to player: WallpaperVideoPlayer, for screen: Screen) {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let powerSource = powerMonitor.currentPowerSource
        let isHiddenByFullScreen = fullScreenDetector.isDesktopHidden(for: screen.id)

        let pauseForPower = WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: globalSettings,
            powerSource: powerSource
        )
        let pauseForFullScreen = WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: globalSettings,
            isHiddenByFullScreen: isHiddenByFullScreen
        )

        if pauseForPower {
            powerPolicy.markPausedByPower(screen.id)
        }
        if pauseForFullScreen {
            powerPolicy.markPausedByFullScreen(screen.id)
        }

        if WallpaperPolicyEngine.shouldStartVideoPaused(
            globalSettings: globalSettings,
            powerSource: powerSource,
            isHiddenByFullScreen: isHiddenByFullScreen
        ) {
            player.pause()
            return
        }

        schedulePolicyAwarePlaybackStart(to: player, screenID: screen.id)
    }

    private func schedulePolicyAwarePlaybackStart(to player: WallpaperVideoPlayer, screenID: CGDirectDisplayID) {
        Task { @MainActor [weak self, weak player] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }

            guard let self, let player else { return }

            let globalSettings = SettingsManager.shared.loadGlobalSettings()
            let shouldPause = WallpaperPolicyEngine.shouldStartVideoPaused(
                globalSettings: globalSettings,
                powerSource: self.powerMonitor.currentPowerSource,
                isHiddenByFullScreen: self.fullScreenDetector.isDesktopHidden(for: screenID)
            )

            guard !shouldPause else {
                player.pause()
                return
            }

            player.play()
            self.markWallpaperSessionStateChanged()
        }
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

    func wallpaperDisplayName(for screen: Screen) -> String? {
        guard let configuration = configurationStore.get(for: screen.id),
              let definition = WallpaperSessionDefinition(configuration: configuration) else { return nil }

        return definition.displayName(using: ResourceUtilities.resolveBookmarkName)
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
    private func handleSystemWake() {
        Logger.info("System wake detected", category: .lifecycle)
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

        releaseRuntimeSession(screen)
        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }
    
    // MARK: - Configuration Update Helpers

    private func saveConfiguration(_ configuration: ScreenConfiguration) {
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
        guard var configuration = configurationStore.get(for: screen.id),
              speed != configuration.playbackSpeed else { return }

        configuration.playbackSpeed = speed
        saveConfiguration(configuration)
        screen.videoPlayer?.setPlaybackSpeed(speed)
    }

    func updateMuted(_ muted: Bool, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id),
              muted != configuration.muted else { return }

        configuration.muted = muted
        saveConfiguration(configuration)
        screen.videoPlayer?.setMuted(muted)
    }

    func updateFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id),
              fitMode != configuration.fitMode else { return }

        configuration.fitMode = fitMode
        saveConfiguration(configuration)
        screen.videoPlayer?.setVideoFitMode(fitMode)
    }

    func updateFrameRateLimit(_ frameRateLimit: FrameRateLimit, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id) else {
            Logger.warning("Cannot update frame rate limit: No configuration found for screen \(screen.id)", category: .videoPlayer)
            return
        }
        guard frameRateLimit != configuration.frameRateLimit else { return }

        configuration.frameRateLimit = frameRateLimit
        saveConfiguration(configuration)
        if configuration.effectConfig.hasActiveEffect {
            applyVideoEffects(for: screen, config: configuration)
        } else {
            applyFrameRateLimit(frameRateLimit, to: screen)
        }
    }
    
    private func applyFrameRateLimit(_ frameRateLimit: FrameRateLimit, to screen: Screen) {
        guard let player = screen.videoPlayer, player.videoFrameRate > 0 else { return }

        let screenRefreshRate = getScreenRefreshRate(for: screen.id)
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: frameRateLimit,
            videoFrameRate: player.videoFrameRate,
            screenRefreshRate: Double(screenRefreshRate)
        )

        if let limit {
            Logger.info("Applying frame rate limit of \(Int(limit)) FPS to screen \(screen.id)", category: .videoPlayer)
            player.setFrameRateLimit(limit)
        } else {
            Logger.info("Using native playback path (\(Int(player.videoFrameRate)) FPS) for screen \(screen.id)", category: .videoPlayer)
            player.setFrameRateLimit(0)
        }
    }
    
    func getConfiguration(for screen: Screen) -> ScreenConfiguration? {
        configurationStore.get(for: screen.id)
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

        let removedScreenIDs = configurationStore.pruneInvalidVideoConfigurations(
            using: SettingsManager.shared.validateConfiguration
        )

        for removedScreenID in removedScreenIDs {
            if let screen = screens.first(where: { $0.id == removedScreenID }) {
                Logger.warning("Removing invalid video configuration for screen \(removedScreenID)", category: .settings)
                releaseRuntimeSession(screen)
            }
        }

        _ = configurationStore.loadAll()

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
        releaseRuntimeSession(screen)

        guard var config = configurationStore.get(for: screen.id),
              config.activateSavedVideoWallpaper() else { return }
        saveConfiguration(config)

        loadConfigurationForScreen(screen)
    }

    private func activateAmbientWallpaper(_ definition: WallpaperSessionDefinition, for screen: Screen) {
        releaseRuntimeSession(screen)

        let session: AmbientWallpaperSession

        switch definition {
        case .html(let source, let htmlConfig):
            session = ambientSessionBuilder.makeHTMLSession(source: source, config: htmlConfig, frame: screen.frame)
            Logger.info("Set HTML wallpaper for screen \(screen.id) — \(source.displayName)", category: .screenManager)
        case .metalShader(let preset):
            session = ambientSessionBuilder.makeShaderSession(preset: preset, frame: screen.frame)
            Logger.info("Set shader wallpaper (\(preset.rawValue)) for screen \(screen.id)", category: .screenManager)
        case .video:
            return
        }

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

    // MARK: - HTML Wallpaper

    func setHTMLWallpaper(source: HTMLSource, config: HTMLConfig = .default, for screen: Screen) {
        var configuration = configurationStore.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .html(source: source, config: config)
        )
        configuration.setHTMLWallpaper(source: source, config: config)
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
              case .html(let source, _) = existing.activeWallpaper else { return }
        existing.activeWallpaper = .html(source: source, config: config)
        saveConfiguration(existing)
        restoreWallpaperSession(for: screen, configuration: existing, preservingState: false)
    }

    // MARK: - Metal Shader Wallpaper

    func setShaderWallpaper(preset: MetalShaderPreset, for screen: Screen) {
        var config = configurationStore.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id, wallpaper: .metalShader(preset)
        )
        config.setShaderWallpaper(preset)
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

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: targetBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        let screenID = screen.id
        let generation = bumpTransition(for: screenID)

        Task { [weak self] in
            do {
                try await PlayableVideoLoader.validatePlayableVideo(at: url)
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
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        let screenID = screen.id
        let generation = bumpTransition(for: screenID)

        Task { [weak self] in
            do {
                try await PlayableVideoLoader.validatePlayableVideo(at: url)
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
