import SwiftUI
import Combine
import AVKit
import os.log
import Observation

// Manages video playback on multiple screens
@MainActor @Observable
final class ScreenManager {
    // MARK: - Properties

    // Note: Since ScreenManager is @MainActor, all access is serialized on the main thread.
    // No locks are needed for thread safety.
    private(set) var screens: [Screen] = []

    /// Last user-facing error, observed by SwiftUI views.
    var lastError: AppError?

    @ObservationIgnored private var cleanupTasks: Set<AnyCancellable> = []
    @ObservationIgnored private let configRepo = ConfigurationRepository()
    @ObservationIgnored private let powerPolicy = PowerPolicyController()
    @ObservationIgnored private let powerMonitor: PowerMonitor = .shared
    @ObservationIgnored private let playbackStateSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored private let fullScreenDetector = FullScreenDetector()
    @ObservationIgnored private let effectsManager = VideoEffectsManager()
    @ObservationIgnored let weatherService = WeatherReactiveService()
    @ObservationIgnored private var scheduleMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var playlistRotationTask: Task<Void, Never>?

    // MARK: - Initialization
    init() {
        Logger.notice("ScreenManager initializing", category: .screenManager)
        setupPowerMonitoring()
        setupScreenObservers()
        setupMemoryMonitoring()
        setupFullScreenDetection()

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
        refreshScreens(preserveVideoPlayers: true)

        // Delay to ensure screen information is fully updated
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.updateAllWindowFrames()
            // Additional check after a short delay to ensure windows stay in position
            try? await Task.sleep(for: .milliseconds(500))
            self?.updateAllWindowFrames()
        }


    }

    /// Updates all video player window frames to match their screen positions
    private func updateAllWindowFrames() {
        for screen in screens {
            guard let player = screen.videoPlayer else { continue }

            if let nsScreen = findNSScreen(for: screen.id) {
                player.updateWindowFrame(nsScreen.frame)
            } else {
                Logger.warning("Could not find NSScreen for screen ID \(screen.id), using stored frame", category: .screenManager)
                player.updateWindowFrame(screen.frame)
            }
        }
    }

    /// Finds the NSScreen object for a given display ID
    private func findNSScreen(for screenID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { nsScreen in
            (nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == screenID
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
        // Perform initial check
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
        guard globalSettings.pauseOnFullScreen else { return }

        for screen in screens {
            guard let player = screen.videoPlayer else { continue }
            let isHidden = hiddenScreens[screen.id] ?? false

            if isHidden && player.isPlaying {
                player.pause()
                powerPolicy.markPausedByFullScreen(screen.id)
            } else if !isHidden && powerPolicy.wasPausedByFullScreen(screen.id) {
                player.play()
                powerPolicy.markResumedFromFullScreen(screen.id)
            }
        }
        updatePlaybackState()
    }

    // MARK: - Screen Management
    func refreshScreens(preserveVideoPlayers: Bool = true) {
        // Get all current screens from system
        let newScreens = NSScreen.screens.map { Screen(nsScreen: $0) }
        Logger.screensDetected(newScreens.count)

        let oldScreens = screens
        let oldScreenIDs = Set(oldScreens.map(\.id))
        let newScreenIDs = Set(newScreens.map(\.id))

        // Clean up removed screens
        for screenID in oldScreenIDs.subtracting(newScreenIDs) {
            if let screen = oldScreens.first(where: { $0.id == screenID }) {
                Logger.info("Cleaning up removed screen \(screenID)", category: .screenManager)
                cleanupScreen(screen)
            }
            
        }
        
        // Preserve existing video players for screens that are still present
        var updatedScreens = [Screen]()
        
        for newScreen in newScreens {
            // Check if this screen existed before
            if preserveVideoPlayers, let existingScreen = oldScreens.first(where: { $0.id == newScreen.id }) {
                // Preserve the video player from the existing screen
                newScreen.videoPlayer = existingScreen.videoPlayer
                newScreen.previewPlayer = existingScreen.previewPlayer
                
            }
            
            updatedScreens.append(newScreen)
        }

        // Update screens array
        screens = updatedScreens

        // Configure newly added screens (only those that weren't present before)
        for screen in newScreens where newScreenIDs.subtracting(oldScreenIDs).contains(screen.id) {
            Logger.info("Configuring new screen \(screen.id)", category: .screenManager)
            loadConfigurationForScreen(screen)
        }
        

        updatePlaybackState()
        
        // Post notification that screens were refreshed
        NotificationCenter.default.post(name: .screensRefreshed, object: nil)
    }
    
    func clearVideoForScreen(_ screen: Screen) {
        Logger.info("Clearing video for screen \(screen.id)", category: .screenManager)
        // Clean up existing video player
        screen.videoPlayer?.cleanup()
        screen.videoPlayer = nil

        // Clean up preview player
        screen.previewPlayer?.pause()
        screen.previewPlayer = nil

        // Remove configuration from settings
        SettingsManager.shared.cleanSettingsForScreen(screen.id)

        // Remove from cache
        configRepo.remove(for: screen.id)

        // Remove from power management tracking
        powerPolicy.clearTracking(for: screen.id)
    }

    private func cleanupScreen(_ screen: Screen) {
        screen.videoPlayer?.cleanup()
        screen.videoPlayer = nil
        screen.previewPlayer?.pause()
        screen.previewPlayer = nil
        // Remove from power management tracking
        powerPolicy.clearTracking(for: screen.id)
    }
    
    // MARK: - Configuration Management
    private func loadSavedConfigurations() {
        let configurations = configRepo.loadAll()

        for configuration in configurations {
            if let screen = screens.first(where: { $0.id == configuration.screenID }) {
                loadConfigurationForScreen(screen)
            }
        }
    }
    
    private func loadConfigurationForScreen(_ screen: Screen) {
        // If screen already has a video player, just update settings
        if screen.videoPlayer != nil {
            if let cachedConfig = configRepo.get(for: screen.id) {
                // Apply configuration without recreating the player
                applyConfiguration(cachedConfig, to: screen, preservingState: true)
            }
            return
        }

        guard let config = configRepo.get(for: screen.id) else { return }

        // Restore non-video wallpaper modes without trying to resolve a video bookmark.
        switch config.wallpaperType {
        case .html:
            if let url = config.htmlContent, !url.isEmpty {
                setHTMLWallpaper(url: url, for: screen)
            }
        case .metalShader:
            if let preset = config.shaderPreset {
                setShaderWallpaper(preset: preset, for: screen)
            }
        case .video:
            applyConfiguration(config, to: screen)
        }
    }
    
    // MARK: - Video Management
    func setVideo(url: URL, bookmarkData: Data, for screen: Screen) {
        Logger.info("Setting video for screen \(screen.id): \(url.lastPathComponent)", category: .screenManager)
        
        // Skip full reload if the same video is already configured.
        if let existingConfig = configRepo.get(for: screen.id) {
            var isStale = false
            if let existingURL = try? URL(
                resolvingBookmarkData: existingConfig.videoBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), existingURL == url {
                updateExistingVideoConfiguration(existingConfig, url: url, bookmarkData: bookmarkData, for: screen)
                return
            }
        }

        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let configuration = ScreenConfiguration(
            screenID: screen.id,
            videoBookmarkData: bookmarkData,
            playbackSpeed: 1.0,
            fitMode: .aspectFill,
            pauseOnBattery: globalSettings.globalPauseOnBattery,
            frameRateLimit: FrameRateLimit.fps60
        )
        
        configRepo.save(configuration)

        // Validate configuration was saved correctly
        if SettingsManager.shared.validateConfiguration(for: screen.id) {
            // Hold a security scope for the duration of the async asset validation —
            // the caller's scope (if any) may be released before this Task runs.
            let scopedURL = url
            let didStartScope = scopedURL.startAccessingSecurityScopedResource()
            Task {
                defer {
                    if didStartScope {
                        scopedURL.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let asset = AVURLAsset(url: scopedURL)
                    let isPlayable = try await asset.load(.isPlayable)

                    guard isPlayable else {
                        throw NSError(domain: "ScreenManager", code: 404, userInfo: [
                            NSLocalizedDescriptionKey: "The selected video is not playable."
                        ])
                    }

                    await MainActor.run { [weak self] in
                        self?.setupVideoPlayback(asset: asset, screen: screen)
                    }
                } catch {
                    await MainActor.run {
                        Logger.error("Failed to setup video: \(error.localizedDescription)", category: .screenManager)
                    }
                }
            }
        } else {
            Logger.error("Failed to save video configuration for screen \(screen.id)", category: .screenManager)
        }
    }
    
    private func updateExistingVideoConfiguration(_ existingConfig: ScreenConfiguration, url: URL, bookmarkData: Data, for screen: Screen) {
        // Update the bookmark data while preserving other settings
        let updatedConfig = existingConfig.withUpdatedBookmark(bookmarkData)
        saveConfiguration(updatedConfig)
    }
    
    private func applyConfiguration(_ configuration: ScreenConfiguration, to screen: Screen, preservingState: Bool = false) {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: configuration.videoBookmarkData,
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
                    let updatedConfig = configuration.withUpdatedBookmark(updatedBookmarkData)
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
                    (SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery || configuration.pauseOnBattery)
                    
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
                screen.videoPlayer = player

                // Apply settings that don't depend on asset metadata immediately.
                player.setPlaybackSpeed(configuration.playbackSpeed)

                // Defer particle / frame-rate / effects until the asset's metadata
                // is actually known (videoFrameRate transitions from 0). Using a
                // readiness signal instead of a fixed delay avoids silently dropping
                // saved state on slow loads.
                applyConfigurationWhenAssetReady(player: player, screen: screen, configuration: configuration)

                // Check if we should play based on power state
                let shouldPause = powerMonitor.currentPowerSource.isOnBattery &&
                (SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery || configuration.pauseOnBattery)

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

    private func setupVideoPlayback(asset: AVURLAsset, screen: Screen) {
        cleanupScreen(screen)
        
        // Create preview player for settings UI
        let previewPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        previewPlayer.volume = 0
        
        // Get configuration
        let configuration = configRepo.get(for: screen.id)
        
        // Create wallpaper player
        let player = WallpaperVideoPlayer(
            url: asset.url,
            frame: screen.frame,
            fitMode: configuration?.fitMode ?? .aspectFill
        )
        
        // Update screen properties
        if let index = screens.firstIndex(where: { $0.id == screen.id }) {
            screens[index].videoPlayer = player
            // Retain a security scope for the preview player's lifetime — AVFoundation
            // reads file data lazily, so the scope must outlive AVAsset construction.
            // The wallpaper player owns its own scope independently in setupPlayer().
            screens[index].retainPreviewSecurityScope(asset.url)
            screens[index].previewPlayer = previewPlayer

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
                    previewPlayer.play()
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
    
    // Method to check and publish global playback state
    private func updatePlaybackState() {
        let isAnyPlaying = screens.contains { $0.videoPlayer?.isPlaying ?? false }

        // Only publish if the state actually changed
        if playbackStateSubject.value != isAnyPlaying {
            playbackStateSubject.send(isAnyPlaying)
        }
    }

    func togglePlayback() {
        let isAnyPlaying = screens.contains { $0.videoPlayer?.isPlaying ?? false }

        Logger.info("Toggling global playback: \(isAnyPlaying ? "pausing" : "playing") all videos", category: .videoPlayer)

        // Toggle playback based on current state
        for screen in screens {
            if let player = screen.videoPlayer {
                if isAnyPlaying {
                    // When user manually pauses, remove from power management tracking
                    // so it won't auto-resume when AC power reconnects
                    powerPolicy.markResumedFromPower(screen.id)
                    player.pause()
                } else {
                    player.play()
                }
            }
        }

        // Update the playback state
        updatePlaybackState()
    }
    
    // MARK: - Power Management
    private func handlePowerStateChange(_ powerSource: PowerMonitor.PowerSource) {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let isOnBattery = powerSource.isOnBattery

        // Batch updates to avoid multiple UI updates
        var updatedScreens = false

        for screen in screens {
            guard let player = screen.videoPlayer else {
                continue
            }

            let configuration = configRepo.get(for: screen.id)
            let shouldPauseForPower = (globalSettings.globalPauseOnBattery || configuration?.pauseOnBattery == true) && isOnBattery

            // Check for low battery threshold
            var shouldPauseForLowBattery = false
            if let batteryLevel = globalSettings.minimumBatteryLevel, isOnBattery {
                if case .battery(let level) = powerSource, level < batteryLevel {
                    shouldPauseForLowBattery = true
                }
            }

            let currentlyPlaying = player.isPlaying

            // Handle pausing when on battery power
            if (shouldPauseForPower || shouldPauseForLowBattery) && currentlyPlaying {
                if shouldPauseForLowBattery {
                    Logger.debug("Pausing screen \(screen.id) due to low battery level", category: .powerMonitor)
                } else {
                    Logger.debug("Pausing screen \(screen.id) due to battery power", category: .powerMonitor)
                }
                player.pause()
                // Track that this screen was paused by power management
                powerPolicy.markPausedByPower(screen.id)
                updatedScreens = true
            }
            // Handle resuming when AC power is connected
            // ONLY resume screens that were paused by power management, not manually paused screens
            else if !isOnBattery && !currentlyPlaying && powerPolicy.wasPausedByPower(screen.id) {
                Logger.debug("Resuming screen \(screen.id) due to external power (was paused by power management)", category: .powerMonitor)
                player.play()
                // Remove from tracking set since we've resumed it
                powerPolicy.markResumedFromPower(screen.id)
                updatedScreens = true
            }
        }

        // When switching to AC power, clear any remaining tracked screens that no longer exist
        if !isOnBattery {
            let currentScreenIDs = Set(screens.map(\.id))
            powerPolicy.cleanUpStaleEntries(currentScreenIDs: currentScreenIDs)
        }

        // Apply battery resolution cap
        if globalSettings.batteryResolutionCap {
            for screen in screens {
                screen.videoPlayer?.setBatteryResolutionCap(isOnBattery)
            }
        }

        if updatedScreens {
            updatePlaybackState()
        }
    }
    
    func handleGlobalPauseOnBatteryChange(_ pauseOnBattery: Bool) {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.globalPauseOnBattery = pauseOnBattery
        SettingsManager.shared.saveGlobalSettings(settings)
        
        Logger.info("Global pause on battery setting changed to \(pauseOnBattery)", category: .settings)
        
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
    
    // MARK: - Public Interface
    // Reload the video for a specific screen
    func reloadVideoForScreen(_ screen: Screen) {
        Logger.info("Manually reloading video for screen \(screen.id)", category: .screenManager)
        if let configuration = configRepo.get(for: screen.id) {
            // Force recreation of player by setting preservingState to false
            applyConfiguration(configuration, to: screen, preservingState: false)
        }
    }
    
    // MARK: - Configuration Update Helpers

    /// Saves and caches the updated configuration
    private func saveConfiguration(_ configuration: ScreenConfiguration) {
        configRepo.save(configuration)
    }

    // Update the playback speed for a screen
    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        guard var configuration = configRepo.get(for: screen.id),
              speed != configuration.playbackSpeed else { return }

        configuration.playbackSpeed = speed
        saveConfiguration(configuration)
        screen.videoPlayer?.setPlaybackSpeed(speed)
    }

    // Update the fit mode for a screen
    func updateFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard var configuration = configRepo.get(for: screen.id),
              fitMode != configuration.fitMode else { return }

        configuration.fitMode = fitMode
        saveConfiguration(configuration)
        screen.videoPlayer?.setVideoFitMode(fitMode)
    }

    // Update the frame rate limit for a screen
    func updateFrameRateLimit(_ frameRateLimit: FrameRateLimit, for screen: Screen) {
        guard var configuration = configRepo.get(for: screen.id) else {
            Logger.warning("Cannot update frame rate limit: No configuration found for screen \(screen.id)", category: .videoPlayer)
            return
        }
        guard frameRateLimit != configuration.frameRateLimit else { return }

        configuration.frameRateLimit = frameRateLimit
        saveConfiguration(configuration)
        applyFrameRateLimit(frameRateLimit, to: screen)
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
        return configRepo.get(for: screen.id)
    }
    
    // Update power settings for a screen
    func updatePowerSettings(pauseOnBattery: Bool, for screen: Screen) {
        guard var configuration = getConfiguration(for: screen),
              pauseOnBattery != configuration.pauseOnBattery else { return }

        configuration.pauseOnBattery = pauseOnBattery
        saveConfiguration(configuration)

        // Apply the new setting immediately based on power state
        let isOnBattery = powerMonitor.currentPowerSource.isOnBattery
        if isOnBattery && pauseOnBattery {
            screen.videoPlayer?.pause()
            powerPolicy.markPausedByPower(screen.id)
        }
        // Don't unconditionally resume when on AC — respect manual pause state
    }
    
    // Validate all saved configurations
    func validateAllConfigurations() -> (valid: Int, invalid: Int) {
        let screenIDs = configRepo.allCachedScreenIDs()
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
    
    // Reload all screens
    func reloadAllScreens() {
        Logger.notice("Reloading all screens", category: .screenManager)

        // Invalidate cached bookmark data to force a fresh reload — only for video configs.
        for screenID in configRepo.allCachedScreenIDs() {
            guard let cached = configRepo.get(for: screenID), cached.wallpaperType == .video else { continue }
            if !SettingsManager.shared.validateConfiguration(for: screenID) {
                Logger.warning("Removing invalid video configuration for screen \(screenID)", category: .settings)
                configRepo.remove(for: screenID)
            }
        }

        // Reload all screens, branching on wallpaper type so HTML/shader survive.
        for screen in screens {
            guard let configuration = SettingsManager.shared.getConfiguration(for: screen.id) else { continue }
            configRepo.save(configuration)

            switch configuration.wallpaperType {
            case .html:
                if let url = configuration.htmlContent, !url.isEmpty {
                    setHTMLWallpaper(url: url, for: screen)
                }
            case .metalShader:
                if let preset = configuration.shaderPreset {
                    setShaderWallpaper(preset: preset, for: screen)
                }
            case .video:
                applyConfiguration(configuration, to: screen, preservingState: false)
            }
        }

        Logger.notice("All screens reloaded", category: .screenManager)
    }
    
    // MARK: - Desktop Picture from Frame

    /// Persist whether the user wants the current frame applied as the desktop picture.
    /// (macOS exposes no public lock-screen wallpaper API; the existing implementation
    /// uses NSWorkspace.setDesktopImageURL which sets the desktop picture.)
    func updateSetAsDesktopPicture(_ enabled: Bool, for screen: Screen) {
        guard var config = configRepo.get(for: screen.id),
              config.setAsLockScreen != enabled else { return }
        config.setAsLockScreen = enabled
        saveConfiguration(config)
    }

    func extractLockScreenFrame(for screen: Screen) {
        guard let player = screen.videoPlayer?.player,
              let currentItem = player.currentItem else { return }

        let asset = currentItem.asset
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let currentTime = player.currentTime()
        nonisolated(unsafe) let generator = imageGenerator

        Task {
            do {
                let (cgImage, _) = try await generator.image(at: currentTime)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

                // Save to a temp file
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LiveWallpaper_LockScreen_\(screen.id).png")

                if let tiffData = nsImage.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    try pngData.write(to: tempURL)

                    // Set as desktop wallpaper (visible on lock screen)
                    if let nsScreen = findNSScreen(for: screen.id) {
                        try NSWorkspace.shared.setDesktopImageURL(tempURL, for: nsScreen, options: [:])
                        Logger.info("Set lock screen wallpaper for screen \(screen.id)", category: .screenManager)
                    }
                }
            } catch {
                Logger.error("Failed to extract lock screen frame: \(error.localizedDescription)", category: .screenManager)
            }
        }
    }

    // MARK: - Video Effects

    func updateEffectConfig(_ effectConfig: VideoEffectConfig, for screen: Screen) {
        guard var config = configRepo.get(for: screen.id) else { return }
        config.effectConfig = effectConfig
        saveConfiguration(config)
        applyVideoEffects(for: screen, config: config)
    }

    func updateParticleEffect(_ effect: ParticleEffect, for screen: Screen) {
        guard var config = configRepo.get(for: screen.id) else { return }
        config.particleEffect = effect
        saveConfiguration(config)
        applyParticleEffect(effect, density: config.effectConfig.particleDensity, to: screen)
    }

    func updateParticleDensity(_ density: Double, for screen: Screen) {
        guard var config = configRepo.get(for: screen.id) else { return }
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
        guard var config = configRepo.get(for: screen.id) else { return }
        config.effectConfig.weatherReactive = enabled
        saveConfiguration(config)

        if enabled {
            weatherService.startMonitoring()
            applyWeatherEffects(for: screen)
        } else {
            // Revert to manual settings — preserve persisted particle density.
            applyParticleEffect(config.particleEffect, density: config.effectConfig.particleDensity, to: screen)
            applyVideoEffects(for: screen, config: config)
        }
    }

    /// Apply current weather conditions to a screen's effects.
    func applyWeatherEffects(for screen: Screen) {
        guard let config = configRepo.get(for: screen.id),
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

    /// Subscribe to WeatherReactiveService updates and apply them to weather-reactive
    /// screens. WeatherReactiveService owns the polling schedule (15-min loop), so
    /// ScreenManager only reacts when fresh data arrives instead of double-scheduling.
    func startWeatherMonitoring() {
        observeWeatherChanges()
    }

    private func observeWeatherChanges() {
        withObservationTracking {
            // Track the observable state we react to.
            _ = weatherService.currentParticleEffect
            _ = weatherService.currentEffectAdjustments
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for screen in self.screens {
                    guard let config = self.configRepo.get(for: screen.id),
                          config.effectConfig.weatherReactive else { continue }
                    self.applyWeatherEffects(for: screen)
                }
                self.observeWeatherChanges()
            }
        }
    }

    func updateVideoEffects(for screen: Screen) {
        guard let config = configRepo.get(for: screen.id) else { return }
        applyVideoEffects(for: screen, config: config)
    }

    private func applyVideoEffects(for screen: Screen, config: ScreenConfiguration) {
        guard let player = screen.videoPlayer,
              let playerItem = player.player?.currentItem else {
            Logger.warning("Cannot apply effects: no active player for screen \(screen.id)", category: .videoPlayer)
            return
        }

        let hasEffects = config.effectConfig.hasActiveEffect || config.effectConfig.autoTimeTint
        Logger.info("Applying effects for screen \(screen.id): hasEffects=\(hasEffects)", category: .videoPlayer)

        if !hasEffects {
            // No effects — reapply plain frame rate limiting (or clear composition)
            applyFrameRateLimit(config.frameRateLimit, to: screen)
            return
        }

        // Effects active — build CIFilter composition (also handles frame rate via frameDuration)
        effectsManager.updateConfig(config.effectConfig)

        // Compute the effective FPS via the shared helper so unlimited mode
        // actually respects screen refresh rate (e.g. caps a 120 fps source at
        // 60 Hz on a non-ProMotion display) instead of hard-coding 60. The
        // helper is unit-tested in isolation.
        let effectiveFPS = FrameRateLimit.resolveCompositionFPS(
            limit: config.frameRateLimit,
            videoFrameRate: player.videoFrameRate,
            screenRefreshRate: Double(getScreenRefreshRate(for: screen.id))
        )
        let safeFPS = max(1.0, effectiveFPS)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(safeFPS))

        Task {
            do {
                let composition = try await effectsManager.buildComposition(
                    for: playerItem.asset,
                    config: config.effectConfig,
                    frameDuration: frameDuration
                )
                await MainActor.run {
                    playerItem.videoComposition = composition
                }
            } catch {
                Logger.error("Failed to apply video effects: \(error.localizedDescription)", category: .videoPlayer)
            }
        }
    }

    // MARK: - Wallpaper Type Switching

    /// Close any non-video wallpaper window and restore the video player
    func switchToVideoWallpaper(for screen: Screen) {
        screen.activeWallpaperWindow = nil  // closes old window via willSet
        screen.activeWallpaperType = .video

        guard var config = configRepo.get(for: screen.id) else { return }
        config.wallpaperType = .video
        saveConfiguration(config)

        // Restore video player from saved config
        loadConfigurationForScreen(screen)

    }

    // MARK: - HTML Wallpaper

    func setHTMLWallpaper(url: String, for screen: Screen) {
        // Save config (create one if it doesn't exist yet)
        var config = configRepo.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id, videoBookmarkData: Data()
        )
        config.wallpaperType = .html
        config.htmlContent = url
        saveConfiguration(config)

        // Clean up existing wallpaper (video + old window)
        cleanupScreen(screen)

        // Create HTML wallpaper
        let window = VideoWallpaperWindow(frame: screen.frame)
        let htmlView = HTMLWallpaperView(frame: screen.frame)
        window.contentView = htmlView

        if let parsedURL = URL(string: url), url.hasPrefix("http") {
            htmlView.loadURL(parsedURL)
        } else if FileManager.default.fileExists(atPath: url) {
            htmlView.loadFile(URL(fileURLWithPath: url))
        } else {
            htmlView.loadHTML(url)
        }

        window.orderBack(nil)
        screen.activeWallpaperWindow = window
        screen.activeWallpaperType = .html

        Logger.info("Set HTML wallpaper for screen \(screen.id)", category: .screenManager)

    }

    // MARK: - Metal Shader Wallpaper

    func setShaderWallpaper(preset: MetalShaderPreset, for screen: Screen) {
        var config = configRepo.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id, videoBookmarkData: Data()
        )
        config.wallpaperType = .metalShader
        config.shaderPreset = preset
        saveConfiguration(config)

        // Clean up existing wallpaper
        cleanupScreen(screen)

        let window = VideoWallpaperWindow(frame: screen.frame)
        let metalView = MetalWallpaperView(frame: screen.frame)
        metalView.setPreset(preset)
        window.contentView = metalView
        window.orderBack(nil)

        screen.activeWallpaperWindow = window
        screen.activeWallpaperType = .metalShader

        Logger.info("Set shader wallpaper (\(preset.rawValue)) for screen \(screen.id)", category: .screenManager)

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
        guard var config = configRepo.get(for: screen.id) else { return }
        config.playlistBookmarks = bookmarks.isEmpty ? nil : bookmarks
        saveConfiguration(config)
    }

    func updateShufflePlaylist(_ shuffle: Bool, for screen: Screen) {
        guard var config = configRepo.get(for: screen.id) else { return }
        config.shufflePlaylist = shuffle
        saveConfiguration(config)
    }

    /// Advance to the next video in the playlist for the given screen.
    /// Preserves all existing settings (effects, particles, playlist, etc.).
    func advancePlaylist(for screen: Screen) {
        guard let config = configRepo.get(for: screen.id) else { return }

        // Build full playlist: primary video + additional videos
        let additionalBookmarks = config.playlistBookmarks ?? []
        let fullPlaylist = [config.videoBookmarkData] + additionalBookmarks
        guard fullPlaylist.count > 1 else { return }

        // Pick next bookmark
        let nextBookmark: Data
        if config.shufflePlaylist {
            // Shuffle: pick random, avoid replaying current
            let candidates = fullPlaylist.filter { $0 != config.videoBookmarkData }
            nextBookmark = candidates.randomElement() ?? fullPlaylist[0]
        } else {
            // Sequential round-robin through full playlist
            let currentIndex = fullPlaylist.firstIndex(of: config.videoBookmarkData) ?? 0
            let nextIndex = (currentIndex + 1) % fullPlaylist.count
            nextBookmark = fullPlaylist[nextIndex]
        }

        guard nextBookmark != config.videoBookmarkData else { return }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: nextBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        // Preserve all settings (effects, particles, playlist, etc.) — only swap the video
        let updatedConfig = config.withUpdatedBookmark(nextBookmark)
        saveConfiguration(updatedConfig)

        Logger.info("Playlist: advancing to \(url.lastPathComponent) for screen \(screen.id)", category: .screenManager)

        // Clean up old player and set up new one with preserved config
        cleanupScreen(screen)

        // Hold scope across the async asset validation. WallpaperVideoPlayer.setupPlayer
        // will start its own scope; we balance ours via defer.
        let didStartScope = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if didStartScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let asset = AVURLAsset(url: url)
                let isPlayable = try await asset.load(.isPlayable)
                guard isPlayable else { return }
                await MainActor.run { [weak self] in
                    self?.setupVideoPlayback(asset: asset, screen: screen)
                }
            } catch {
                Logger.error("Playlist advance failed: \(error.localizedDescription)", category: .screenManager)
            }
        }
    }

    // MARK: - Schedule Management

    func updateScheduleSlots(_ slots: [ScheduleSlot]?, for screen: Screen) {
        guard var config = configRepo.get(for: screen.id) else { return }
        config.scheduleSlots = slots
        saveConfiguration(config)

        if slots != nil {
            checkAndApplySchedule(for: screen)
        }
    }

    /// Check the current hour and switch to the scheduled video if needed.
    func checkAndApplySchedule(for screen: Screen) {
        guard let config = configRepo.get(for: screen.id),
              let slots = config.scheduleSlots,
              !slots.isEmpty else { return }

        let currentHour = Calendar.current.component(.hour, from: Date())

        guard let activeSlot = slots.first(where: { $0.containsHour(currentHour) }),
              let bookmarkData = activeSlot.videoBookmarkData else { return }

        // Skip if the scheduled video is already playing
        guard config.videoBookmarkData != bookmarkData else { return }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        Logger.info("Schedule: switching to \(activeSlot.label) wallpaper for screen \(screen.id)", category: .screenManager)
        setVideo(url: url, bookmarkData: bookmarkData, for: screen)
    }

    /// Periodically checks all screens for schedule and playlist rotation.
    /// Both Tasks are stored so they can be cancelled on teardown.
    func startScheduleMonitoring() {
        scheduleMonitorTask?.cancel()
        playlistRotationTask?.cancel()

        // Schedule-based switching (check every 60s)
        scheduleMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                for screen in self.screens {
                    self.checkAndApplySchedule(for: screen)
                }
            }
        }

        // Playlist time-based rotation (check every 60s)
        playlistRotationTask = Task { [weak self] in
            var lastRotation: [CGDirectDisplayID: Date] = [:]

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }

                let now = Date()
                for screen in self.screens {
                    guard let config = self.configRepo.get(for: screen.id),
                          let rotationMinutes = config.playlistRotationMinutes,
                          rotationMinutes > 0,
                          let bookmarks = config.playlistBookmarks,
                          !bookmarks.isEmpty else { continue }

                    let lastTime = lastRotation[screen.id] ?? now
                    if lastRotation[screen.id] == nil {
                        lastRotation[screen.id] = now
                        continue
                    }

                    let elapsed = now.timeIntervalSince(lastTime)
                    if elapsed >= Double(rotationMinutes) * 60.0 {
                        lastRotation[screen.id] = now
                        self.advancePlaylist(for: screen)
                    }
                }
            }
        }
    }

    func updatePlaylistRotationMinutes(_ minutes: Int?, for screen: Screen) {
        guard var config = configRepo.get(for: screen.id) else { return }
        config.playlistRotationMinutes = minutes
        saveConfiguration(config)
    }

    func applySettingsToAllScreens(from sourceScreen: Screen) {
        guard let sourceConfig = configRepo.get(for: sourceScreen.id) else { return }
        for screen in screens where screen.id != sourceScreen.id {
            guard var targetConfig = configRepo.get(for: screen.id) else { continue }
            targetConfig.effectConfig = sourceConfig.effectConfig
            targetConfig.particleEffect = sourceConfig.particleEffect
            targetConfig.fitMode = sourceConfig.fitMode
            targetConfig.playbackSpeed = sourceConfig.playbackSpeed
            targetConfig.frameRateLimit = sourceConfig.frameRateLimit
            saveConfiguration(targetConfig)
            // Apply live — pair particle effect with its density to avoid resets.
            screen.videoPlayer?.setVideoFitMode(sourceConfig.fitMode)
            screen.videoPlayer?.setPlaybackSpeed(sourceConfig.playbackSpeed)
            applyParticleEffect(
                sourceConfig.particleEffect,
                density: sourceConfig.effectConfig.particleDensity,
                to: screen
            )
            applyVideoEffects(for: screen, config: targetConfig)
        }
    }

    nonisolated deinit {}
}
