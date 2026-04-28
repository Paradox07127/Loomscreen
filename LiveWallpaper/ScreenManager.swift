import SwiftUI
import Combine
import Observation

// Orchestrates wallpaper sessions across all connected screens.
@MainActor @Observable
final class ScreenManager {
    // MARK: - Properties

    // Note: Since ScreenManager is @MainActor, all access is serialized on the main thread.
    // No locks are needed for thread safety.
    private(set) var screens: [Screen] = []

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
    /// Per-screen monotonic counter — bumped each time we kick off a video
    /// transition (setVideo / playlist jump). Tasks capture the bumped value
    /// and only apply if it matches at completion, preventing a stale validate
    /// from overwriting a newer one.
    @ObservationIgnored private var transitionGeneration: [CGDirectDisplayID: Int] = [:]
    @ObservationIgnored let weatherService = WeatherReactiveService()
    @ObservationIgnored private lazy var lockScreenSnapshotCoordinator = LockScreenSnapshotCoordinator { [weak self] in
        self?.captureDesktopSnapshotsForLockIfNeeded()
    }
    // MARK: - Initialization
    init() {
        Logger.notice("ScreenManager initializing", category: .screenManager)
        setupPowerMonitoring()
        setupScreenObservers()
        setupMemoryMonitoring()
        setupFullScreenDetection()
        _ = lockScreenSnapshotCoordinator

        // Add notification observer for video player playback state changes
        NotificationCenter.default.publisher(for: WallpaperVideoPlayer.didChangePlaybackStateNotification)
            .sink { [weak self] _ in
                self?.updatePlaybackState()
            }
            .store(in: &cleanupTasks)

        refreshScreens()
        loadSavedConfigurations()
        startScheduleMonitoring()
        startWeatherMonitoring()
        Logger.notice("ScreenManager initialization complete", category: .screenManager)
    }
    
    // MARK: - Observers Setup
    private func setupPowerMonitoring() {
        powerMonitor.powerSourcePublisher
            .sink { [weak self] powerSource in
                self?.handlePowerStateChange(powerSource)
            }
            .store(in: &cleanupTasks)
        
        // Apply initial power state
        let initialPowerSource = powerMonitor.currentPowerSource
        handlePowerStateChange(initialPowerSource)
    }
    
    private func setupScreenObservers() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            // Use a more aggressive throttling for intensive screen changes
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

        // Delay to ensure screen information is fully updated
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.updateAllWindowFrames()
            // Additional check after a short delay to ensure windows stay in position
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
        // Observe hiddenScreens changes from @Observable FullScreenDetector
        // using a recursive withObservationTracking loop.
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
                // Mark-paused-by-full-screen only when the session was ACTIVELY
                // playing at the time. If it was already paused (e.g. by power
                // policy), skipping the mark is correct: exit-full-screen must
                // not "resume" something the user/power didn't want playing.
                if let playback = screen.playbackController, playback.isPlaying {
                    playback.pause()
                    powerPolicy.markPausedByFullScreen(screen.id)
                }
                // Don't orderOut the wallpaper window: keep the frozen frame visible
                // during Mission Control / Spaces swipe instead of revealing the system
                // wallpaper. pause + .suspended profile already stops decoding.
            } else {
                if let playback = screen.playbackController,
                   powerPolicy.wasPausedByFullScreen(screen.id) {
                    playback.play()
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

        // Clean up removed screens
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
            loadConfigurationForScreen(screen)
        }

        updateAllWindowFrames()

        updatePlaybackState()
        updateFullScreenFallbackPolling()

        NotificationCenter.default.post(name: .screensRefreshed, object: nil)
    }

    func clearWallpaperForScreen(_ screen: Screen) {
        Logger.info("Clearing wallpaper for screen \(screen.id)", category: .screenManager)
        screen.resetRuntimeSession()
        configurationStore.remove(for: screen.id)
        powerPolicy.clearTracking(for: screen.id)
        postConfigurationDidChange(for: screen.id)
        notifyWallpaperSessionChanged()
    }

    /// Tears down the live runtime session for a screen without touching persistence.
    /// Use `clearWallpaperForScreen(_:)` when you also want to delete the saved
    /// configuration for that screen.
    private func releaseRuntimeSession(_ screen: Screen) {
        videoEffectsApplier.cancelInflight(for: screen.id)
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
    private func loadSavedConfigurations() {
        let configurations = configurationStore.loadAll()

        for configuration in configurations {
            if let screen = screens.first(where: { $0.id == configuration.screenID }) {
                loadConfigurationForScreen(screen)
            }
        }
    }
    
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

    /// Set (or replace) the primary video for a screen. Existing per-screen
    /// settings — effects, playlist, schedule, fit mode, playback speed, frame
    /// rate limit, power — are all preserved. Only the underlying video file
    /// is swapped, honoring the "just change the video, keep my setup" UX.
    func setVideo(url: URL, bookmarkData: Data, for screen: Screen) {
        Logger.info("Setting video for screen \(screen.id): \(url.lastPathComponent)", category: .screenManager)

        let existing = configurationStore.get(for: screen.id)

        // Is the user re-picking the SAME file? If so we only need to refresh
        // the bookmark and reapply settings on the existing player, avoiding
        // a full reload.
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

        // Build the updated configuration. If there is no prior config, start
        // from defaults (first-time setup); otherwise preserve everything and
        // swap only the primary video identity.
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
            // Keep the existing player; reapply settings on it.
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
            
            // If bookmark is stale, update it
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
            
            // Check if we need to update the player at all
            let needsNewPlayer = screen.videoPlayer == nil
            
            // If we already have a player, use the existing one
            if !needsNewPlayer {
                // Save current playback position if preserving state
                let currentTime = preservingState ? screen.videoPlayer?.player?.currentTime() : .zero
                let wasPlaying = screen.videoPlayer?.isPlaying ?? false
                
                // Apply settings to existing player
                if let player = screen.videoPlayer {
                    // Always update the fit mode - the method will handle if it hasn't changed
                    player.setVideoFitMode(configuration.fitMode)
                    
                    // Update playback speed only if it has changed
                    // Compare against stored speed, not player.rate (which is 0 when paused)
                    let currentSpeed = player.player?.defaultRate ?? 1.0
                    if abs(Float(configuration.playbackSpeed) - currentSpeed) > 0.01 {
                        player.setPlaybackSpeed(configuration.playbackSpeed)
                    }
                    
                    // Update frame rate limit if needed
                    if player.videoFrameRate > 0 {
                        // Get screen refresh rate
                        let screenRefreshRate = getScreenRefreshRate(for: screen.id)
                        // Calculate actual frame rate limit
                        let limit = configuration.frameRateLimit.getEffectiveLimit(
                            videoFrameRate: player.videoFrameRate,
                            screenRefreshRate: Double(screenRefreshRate)
                        )
                        
                        if limit > 0 && limit < Float(player.videoFrameRate) {
                                player.setFrameRateLimit(limit)
                        }
                    }
                    
                    // Restore playback position if needed
                    if let currentTime = currentTime {
                        player.player?.seek(to: currentTime)
                    }
                    
                    // Check if we should pause based on power state
                    let shouldPause = powerMonitor.currentPowerSource.isOnBattery &&
                    SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery

                    if shouldPause && wasPlaying {
                        player.pause()
                    } else if !shouldPause && !wasPlaying {
                        // Small delay to ensure proper initialization
                        Task {
                            try? await Task.sleep(for: .milliseconds(200))
                            player.play()
                        }
                    }
                }
            } else {
                // Create new player with the configuration settings
                let player = WallpaperVideoPlayer(
                    url: url,
                    frame: screen.frame,
                    fitMode: configuration.fitMode
                )
                screen.installRuntimeSession(VideoWallpaperSession(player: player))
                notifyWallpaperSessionChanged()

                // Apply settings that don't depend on asset metadata immediately.
                player.setPlaybackSpeed(configuration.playbackSpeed)

                // Defer particle / frame-rate / effects until the asset's metadata
                // is actually known (videoFrameRate transitions from 0). Using a
                // readiness signal instead of a fixed delay avoids silently dropping
                // saved state on slow loads.
                applyConfigurationWhenAssetReady(player: player, screen: screen, configuration: configuration)

                // Check if we should play based on power state
                let shouldPause = powerMonitor.currentPowerSource.isOnBattery &&
                SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery

                if shouldPause {
                    player.pause()
                } else {
                    // Small delay to ensure proper initialization
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        player.play()
                    }
                }
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
            // NSCocoaError 261 (NSFileReadCorruptFileError) on bookmark
            // resolution means the persisted bookmark format is unrecognised
            // — typically a malformed bookmark from an earlier broken code
            // path. Clear the saved bookmark so the screen returns to the
            // empty state instead of looping the same failure on every
            // refresh / reload.
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadCorruptFileError {
                Logger.warning("Clearing unresolvable bookmark for screen \(screen.id); user must re-pick the source.", category: .screenManager)
                configurationStore.remove(for: screen.id)
                screen.resetRuntimeSession()
                notifyWallpaperSessionChanged()
            }
        } catch {
            Logger.error("Failed to apply configuration: \(error.localizedDescription)", category: .screenManager)
        }
    }
    
    /// Applies configuration that depends on asset metadata once the player has
    /// reported a non-zero `videoFrameRate`. Falls back to a short delay if the
    /// publisher does not emit promptly so we never silently skip the state.
    private func applyConfigurationWhenAssetReady(
        player: WallpaperVideoPlayer,
        screen: Screen,
        configuration: ScreenConfiguration
    ) {
        let screenID = screen.id
        let apply: @MainActor () -> Void = { [weak self] in
            guard let self,
                  let liveScreen = self.screens.first(where: { $0.id == screenID }) else { return }
            if configuration.particleEffect != .none {
                player.setParticleEffect(
                    configuration.particleEffect,
                    density: configuration.effectConfig.particleDensity
                )
            }
            self.applyFrameRateLimit(configuration.frameRateLimit, to: liveScreen)
            if configuration.effectConfig.hasActiveEffect || configuration.effectConfig.autoTimeTint {
                self.applyVideoEffects(for: liveScreen, config: configuration)
            }
        }

        if player.videoFrameRate > 0 {
            apply()
            return
        }

        // Wait for the first non-zero videoFrameRate emission with a hard 5s ceiling.
        var cancellable: AnyCancellable?
        var didApply = false
        cancellable = player.$videoFrameRate
            .first(where: { $0 > 0 })
            .receive(on: DispatchQueue.main)
            .sink { _ in
                guard !didApply else { return }
                didApply = true
                apply()
                cancellable?.cancel()
            }
        if let cancellable {
            cleanupTasks.insert(cancellable)
        }

        // Safety net — if the asset never reports its frame rate (e.g. metadata
        // load error), still try to apply effects after a generous delay so the
        // user's saved state has at least one chance to land.
        let fallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard self != nil, !didApply else { return }
            didApply = true
            apply()
            cancellable?.cancel()
        }
        cleanupTasks.insert(AnyCancellable { fallbackTask.cancel() })
    }

    private func setupVideoPlayback(url: URL, screen: Screen) {
        releaseRuntimeSession(screen)
        
        // Get configuration
        let configuration = configurationStore.get(for: screen.id)
        
        // Create wallpaper player
        let player = WallpaperVideoPlayer(
            url: url,
            frame: screen.frame,
            fitMode: configuration?.fitMode ?? .aspectFill
        )

        // Apply persisted mute state. Default is true so audio tracks stay
        // disabled and AVF never engages the audio engine — protects AirPods
        // and external outputs from being grabbed by a silent wallpaper.
        if let stored = configuration?.muted {
            player.setMuted(stored)
        }

        // Update screen properties
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

            // Check if we should pause based on power state
            let shouldPause = powerMonitor.currentPowerSource.isOnBattery &&
            SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery

            if shouldPause {
                player.pause()
            } else {
                // Delay playback to ensure proper initialization
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    player.play()
                    self?.updatePlaybackState()
                }
            }

            // Apply frame rate limit if configured
            if let frameRateLimit = configuration?.frameRateLimit {
                let screenID = screen.id
                // Delay frame rate limit application to ensure video properties are loaded
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self,
                          let screen = self.screens.first(where: { $0.id == screenID }) else { return }
                    self.applyFrameRateLimit(frameRateLimit, to: screen)
                }
            }

            // Apply saved particle effect (with persisted density)
            if let particleEffect = configuration?.particleEffect, particleEffect != .none {
                player.setParticleEffect(
                    particleEffect,
                    density: configuration?.effectConfig.particleDensity ?? 1.0
                )
            }

            // Apply saved video effects
            if let config = configuration, config.effectConfig.hasActiveEffect {
                applyVideoEffects(for: screen, config: config)
            }

            Logger.info("Video player setup complete for screen \(screen.id)", category: .screenManager)
            notifyWallpaperSessionChanged()
        } else {
            // Handle the case where the screen wasn't found
            Logger.warning("Screen with ID \(screen.id) not found in screens array", category: .screenManager)
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
        screens.map(\.wallpaperSessionSummary)
    }

    var wallpaperOverviewStatus: WallpaperOverviewStatus {
        WallpaperStatusAggregator.overview(for: wallpaperSessionSummaries)
    }

    var hasControllableWallpaperSessions: Bool {
        wallpaperSessionSummaries.contains { $0.isConfigured && $0.supportsPlaybackControl }
    }

    func wallpaperSummary(for screen: Screen) -> WallpaperSessionSummary {
        screen.wallpaperSessionSummary
    }

    func wallpaperDisplayName(for screen: Screen) -> String? {
        guard let configuration = configurationStore.get(for: screen.id),
              let definition = WallpaperSessionDefinition(configuration: configuration) else { return nil }

        return definition.displayName(using: ResourceUtilities.resolveBookmarkName)
    }

    // Method to check and publish global playback state
    private func updatePlaybackState() {
        let isAnyPlaying = screens.contains { $0.playbackController?.isPlaying ?? false }

        // Only publish if the state actually changed
        if playbackStateSubject.value != isAnyPlaying {
            playbackStateSubject.send(isAnyPlaying)
        }
    }

    private func notifyWallpaperSessionChanged() {
        updatePlaybackState()
        updateFullScreenFallbackPolling()
        NotificationCenter.default.post(name: .screensRefreshed, object: nil)
    }

    func togglePlayback() {
        guard hasControllableWallpaperSessions else { return }

        let isAnyPlaying = screens.contains { $0.playbackController?.isPlaying ?? false }

        Logger.info("Toggling global playback: \(isAnyPlaying ? "pausing" : "playing") all videos", category: .videoPlayer)

        // Toggle playback based on current state
        for screen in screens {
            guard let playback = screen.playbackController else { continue }

            if isAnyPlaying {
                // When user manually pauses, remove from power management tracking
                // so it won't auto-resume when AC power reconnects
                powerPolicy.markResumedFromPower(screen.id)
                playback.pause()
            } else {
                playback.play()
            }
        }

        // Update the playback state
        updatePlaybackState()
    }
    
    // MARK: - Power Management
    private func handlePowerStateChange(_ powerSource: PowerMonitor.PowerSource) {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()

        // Batch updates to avoid multiple UI updates
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
                // Video path — explicit pause with bookkeeping in PowerPolicyController.
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
                // Ambient (HTML/Shader) path — no playback controller, so we
                // freeze the animation via `.suspended` and restore on AC.
                // The user's preference is static-on-battery, not degraded
                // animation, so this is the sole battery-saving action.
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

        // When switching to AC power, clear any remaining tracked screens that no longer exist
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

        // If memory is low, pause all videos that aren't visible or active
        for screen in screens {
            if let player = screen.videoPlayer, player.isPlaying {
                // Check if this screen is currently visible/active
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
        // Already on @MainActor, no need for extra Task hop
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

        // User-initiated Reload must rebuild the runtime session from scratch.
        // The reuse branch only updates settings and can't recover a stalled
        // AVQueuePlayer + AVPlayerLooper. Force release so restoreWallpaperSession
        // takes the needsNewPlayer branch.
        releaseRuntimeSession(screen)
        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }
    
    // MARK: - Configuration Update Helpers

    /// Saves and caches the updated configuration, then notifies any view
    /// observing this screen so it can refresh from the new persisted state.
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

    // Update the playback speed for a screen
    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id),
              speed != configuration.playbackSpeed else { return }

        configuration.playbackSpeed = speed
        saveConfiguration(configuration)
        screen.videoPlayer?.setPlaybackSpeed(speed)
    }

    /// Toggle video wallpaper audio for a screen. Default is muted: audio
    /// tracks are disabled at the AVPlayerItem level so AVF never engages
    /// the audio engine, which keeps AirPods/external outputs free. User
    /// opts in per-screen — turning audio on routes through system default
    /// output as usual.
    func updateMuted(_ muted: Bool, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id),
              muted != configuration.muted else { return }

        configuration.muted = muted
        saveConfiguration(configuration)
        screen.videoPlayer?.setMuted(muted)
    }

    // Update the fit mode for a screen
    func updateFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id),
              fitMode != configuration.fitMode else { return }

        configuration.fitMode = fitMode
        saveConfiguration(configuration)
        screen.videoPlayer?.setVideoFitMode(fitMode)
    }

    // Update the frame rate limit for a screen
    func updateFrameRateLimit(_ frameRateLimit: FrameRateLimit, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id) else {
            Logger.warning("Cannot update frame rate limit: No configuration found for screen \(screen.id)", category: .videoPlayer)
            return
        }
        guard frameRateLimit != configuration.frameRateLimit else { return }

        configuration.frameRateLimit = frameRateLimit
        saveConfiguration(configuration)
        // With active effects, frame rate must go through the effects compositor;
        // otherwise the plain frame-rate composition overrides CIFilter composition.
        if configuration.effectConfig.hasActiveEffect || configuration.effectConfig.autoTimeTint {
            applyVideoEffects(for: screen, config: configuration)
        } else {
            applyFrameRateLimit(frameRateLimit, to: screen)
        }
    }
    
    // Apply frame rate limit to a screen's video player
    private func applyFrameRateLimit(_ frameRateLimit: FrameRateLimit, to screen: Screen) {
        guard let player = screen.videoPlayer, player.videoFrameRate > 0 else { return }
        
        // Get screen refresh rate
        let screenRefreshRate = getScreenRefreshRate(for: screen.id)
        
        // Calculate effective limit
        let limit = frameRateLimit.getEffectiveLimit(
            videoFrameRate: player.videoFrameRate,
            screenRefreshRate: Double(screenRefreshRate)
        )
        
        // Apply the limit
        if limit > 0 {
            Logger.info("Applying frame rate limit of \(Int(limit)) FPS to screen \(screen.id)", category: .videoPlayer)
            player.setFrameRateLimit(limit)
        } else {
            // Use video's native frame rate (no limit)
            Logger.info("Using native frame rate (\(Int(player.videoFrameRate)) FPS) for screen \(screen.id)", category: .videoPlayer)
            player.setFrameRateLimit(0)
        }
    }
    
    // Get the saved configuration for a screen
    func getConfiguration(for screen: Screen) -> ScreenConfiguration? {
        return configurationStore.get(for: screen.id)
    }
    
    // Validate all saved configurations
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
    
    /// Force re-read NSScreen + release all runtime sessions + rebuild from persisted config.
    /// Triggered by the sidebar refresh button when system notifications miss a resolution
    /// change (sidebar displays grey out, video disappears).
    func hardRefresh() {
        Logger.notice("Hard refresh: rebuilding display registry + runtime sessions", category: .screenManager)
        refreshRateCache.removeAll()
        // 1) Re-read NSScreen + release all runtime so the screens array reflects the latest frame/ID.
        refreshScreens(preserveRuntimeSessions: false)
        // 2) Rebuild each screen's wallpaper session (video/HTML/Shader) from persisted config.
        reloadAllScreens()
    }

    // Reload all screens
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

            // Same as reloadWallpaperForScreen: batch reload must release runtime
            // sessions before restoring; otherwise the reuse branch keeps a stalled
            // AVQueuePlayer alive.
            releaseRuntimeSession(screen)
            restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
        }

        Logger.notice("All screens reloaded", category: .screenManager)
    }
    
    // MARK: - Desktop Picture from Frame

    /// Persist whether the user wants the current frame applied as the desktop picture.
    /// (macOS exposes no public lock-screen wallpaper API; the existing implementation
    /// uses NSWorkspace.setDesktopImageURL which sets the desktop picture.)
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

    /// Centralized particle application — always pairs effect + density so callers
    /// can never accidentally drop the persisted density.
    private func applyParticleEffect(_ effect: ParticleEffect, density: Double, to screen: Screen) {
        screen.videoPlayer?.setParticleEffect(effect, density: density)
    }

    // MARK: - Weather-Reactive Effects

    /// Enable or disable weather-reactive mode for a screen.
    func setWeatherReactive(_ enabled: Bool, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        config.effectConfig.weatherReactive = enabled
        saveConfiguration(config)
        refreshWeatherMonitoringState()

        if enabled {
            applyWeatherEffects(for: screen)
        } else {
            // Revert to manual settings — preserve persisted particle density.
            applyParticleEffect(config.particleEffect, density: config.effectConfig.particleDensity, to: screen)
            applyVideoEffects(for: screen, config: config)
        }
    }

    /// Apply current weather conditions to a screen's effects.
    func applyWeatherEffects(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id),
              config.effectConfig.weatherReactive else { return }

        // Apply weather-derived particle effect with persisted density.
        applyParticleEffect(
            weatherService.currentParticleEffect,
            density: config.effectConfig.particleDensity,
            to: screen
        )

        // Apply weather-derived CIFilter adjustments
        let adj = weatherService.currentEffectAdjustments
        var weatherConfig = config.effectConfig
        weatherConfig.saturation = adj.saturation
        weatherConfig.brightness = adj.brightness
        weatherConfig.warmth = adj.warmth
        weatherConfig.blurRadius = adj.blurRadius
        weatherConfig.vignetteIntensity = adj.vignetteIntensity

        var updatedConfig = config
        updatedConfig.effectConfig = weatherConfig
        // Don't save — weather adjustments are transient, not persisted
        applyVideoEffects(for: screen, config: updatedConfig)
    }

    /// Reacts to WeatherReactiveService updates; the service owns polling.
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
        // Observation tracking is one-shot; re-register after each update.
        withObservationTracking {
            // Track the observable state we react to.
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

    /// Close any non-video wallpaper window and restore the video player
    func switchToVideoWallpaper(for screen: Screen) {
        screen.clearWallpaperRuntimeSession()

        guard var config = configurationStore.get(for: screen.id),
              config.activateSavedVideoWallpaper() else { return }
        saveConfiguration(config)

        // Restore video player from saved config
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

    /// Apply an arbitrary `HTMLSource` (file/folder/url/inline) using the
    /// supplied `config`. Always overwrites the persisted toggles — call
    /// `setHTMLWallpaperPreservingConfig(source:for:)` from quick actions
    /// when the existing per-screen settings should be kept untouched.
    func setHTMLWallpaper(source: HTMLSource, config: HTMLConfig = .default, for screen: Screen) {
        var configuration = configurationStore.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .html(source: source, config: config)
        )
        configuration.setHTMLWallpaper(source: source, config: config)
        saveConfiguration(configuration)

        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }

    /// Quick-action / menu-bar entry that swaps just the source while
    /// keeping the previously persisted `HTMLConfig` intact (or `.default`
    /// when no prior HTML configuration exists). Mirrors the "swap video,
    /// keep settings" pattern used by `setVideo(...)`.
    func setHTMLWallpaperPreservingConfig(source: HTMLSource, for screen: Screen) {
        let preserved = configurationStore.get(for: screen.id)?.htmlConfig ?? .default
        setHTMLWallpaper(source: source, config: preserved, for: screen)
    }

    /// Legacy URL-string entry point kept for onboarding / quick-input flows.
    /// Internally maps the string to an `HTMLSource` via the shared user-input
    /// heuristic.
    func setHTMLWallpaper(url: String, for screen: Screen) {
        guard let source = HTMLSource(userInput: url) else { return }
        setHTMLWallpaper(source: source, for: screen)
    }

    /// Replace only the `HTMLConfig` for the current HTML wallpaper. No-op
    /// when the active wallpaper is not HTML.
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

    // Cached refresh rates — invalidated on screen parameter change
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

    /// Promote a bookmark to primary; the old primary is appended to the playlist.
    /// Triggers a player rebuild.
    func setPrimaryVideo(bookmark: Data, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id),
              config.savedVideoBookmarkData != bookmark else { return }

        var extras = config.playlistBookmarks ?? []
        // Move old primary into the playlist so it isn't lost.
        if let oldPrimary = config.savedVideoBookmarkData,
           !extras.contains(oldPrimary), oldPrimary != bookmark {
            extras.append(oldPrimary)
        }
        // Remove the new primary from extras to avoid duplication.
        extras.removeAll(where: { $0 == bookmark })

        config.replacePrimaryVideo(bookmarkData: bookmark)
        config.playlistBookmarks = extras.isEmpty ? nil : extras
        saveConfiguration(config)

        // Restart the player so the new primary takes effect immediately.
        reloadWallpaperForScreen(screen)
    }

    /// Atomic update of primary + extras after a drag-reorder. When primary
    /// identity is unchanged, only the playlist order is written (no player rebuild)
    /// and `playlistCursorIndex` is remapped to the new position of the previously
    /// active bookmark so the cursor doesn't jump to the wrong track.
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

    /// Jump to any entry in `[primary] + playlistBookmarks` and play immediately.
    /// `index` 0 = primary; >0 = playlistBookmarks[index-1].
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

    /// Advance to the next video in the playlist for the given screen.
    /// Preserves all existing settings (effects, particles, playlist, etc.).
    /// Cursor-based: the primary (`savedVideoBookmarkData`) stays put, only the
    /// active-playlist cursor moves, so rotation never stalls even when the
    /// current playing bookmark happens to coincide with one of the additional
    /// entries.
    ///
    /// Validates the next bookmark BEFORE saving / releasing the live session
    /// so a missing or unreadable file leaves the user's current wallpaper
    /// playing instead of clearing the screen.
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

    /// Refresh the persisted bookmark associated with the screen's currently
    /// active video. Call when the OS reports a bookmark as stale so the JSON
    /// store stops drifting from the real file location.
    func replaceActiveBookmark(_ bookmarkData: Data, for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id) else { return }
        let updated = config.withUpdatedActiveBookmark(bookmarkData)
        saveConfiguration(updated)
    }

    /// Persist the user's chosen automation mode. No player restart — mode
    /// only gates which automation is consulted.
    func updateWallpaperMode(_ mode: WallpaperMode, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id),
              config.wallpaperMode != mode else { return }
        config.wallpaperMode = mode
        saveConfiguration(config)
    }

    /// Shared logic for advancing/regressing the cursor and activating the target bookmark:
    /// validate → save config → release old session → set up new player.
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

    /// Check the current hour and apply the schedule decision (apply slot,
    /// restore primary when the slot window ends, or no-op).
    ///
    /// Preserves the screen's configuration (effects, particles, playlist,
    /// schedule slots themselves, etc.); only `activeWallpaper` is swapped.
    /// `savedVideoBookmarkData` (the user's primary) is never touched here.
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

    /// Validate first; only mutate config + tear down the live session if the
    /// new bookmark is actually playable. Avoids leaving the screen blank when
    /// a slot/primary file is missing or unreadable.
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

        Task { [weak self] in
            do {
                try await PlayableVideoLoader.validatePlayableVideo(at: url)
                await MainActor.run { [weak self] in
                    guard let self,
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

    /// Periodically checks all screens for schedule and playlist rotation.
    /// Both Tasks are stored so they can be cancelled on teardown.
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

    nonisolated deinit {}
}
