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

        // Auto-advance playlist when a video completes a loop
        NotificationCenter.default.publisher(for: .videoDidCompleteLoop)
            .sink { [weak self] notification in
                guard let self = self,
                      let videoPlayer = notification.object as? WallpaperVideoPlayer else { return }
                // Find the screen this player belongs to
                if let screen = self.screens.first(where: { $0.videoPlayer === videoPlayer }),
                   let config = self.configRepo.get(for: screen.id),
                   config.playlistBookmarks != nil, !(config.playlistBookmarks?.isEmpty ?? true) {
                    self.advancePlaylist(for: screen)
                }
            }
            .store(in: &cleanupTasks)

        refreshScreens()
        loadSavedConfigurations()
        startScheduleMonitoring()
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

        if let config = configRepo.get(for: screen.id) {
            applyConfiguration(config, to: screen)
        }
    }
    
    // MARK: - Video Management
    func setVideo(url: URL, bookmarkData: Data, for screen: Screen) {
        Logger.info("Setting video for screen \(screen.id): \(url.lastPathComponent)", category: .screenManager)
        
        // Check if we're just updating the same video to avoid unnecessary reloads
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
        
        // Get default global settings
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        
        // Otherwise, create a new configuration
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
            Task {
                do {
                    let asset = AVURLAsset(url: url)
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
                
                // Apply settings
                player.setPlaybackSpeed(configuration.playbackSpeed)
                
                // Apply frame rate limit if configured
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

            // Only notify of changes if something important changed
            if needsNewPlayer {
        
            }
            
        } catch {
            Logger.error("Failed to apply configuration: \(error.localizedDescription)", category: .screenManager)
        }
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
                    guard let self = self,
                          let screen = self.screens.first(where: { $0.id == screenID }) else { return }
                    self.applyFrameRateLimit(frameRateLimit, to: screen)
                }
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
            applyConfiguration(configuration, to: screen, preservingState: true)
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

        // Invalidate cached bookmark data to force a fresh reload
        for screenID in configRepo.allCachedScreenIDs() {
            if !SettingsManager.shared.validateConfiguration(for: screenID) {
                Logger.warning("Removing invalid configuration for screen \(screenID)", category: .settings)
                configRepo.remove(for: screenID)
            }
        }

        // Reload all screens
        for screen in screens {
            if let configuration = SettingsManager.shared.getConfiguration(for: screen.id) {
                configRepo.save(configuration)
                applyConfiguration(configuration, to: screen, preservingState: false)
            }
        }
        
        Logger.notice("All screens reloaded", category: .screenManager)
    }
    
    // MARK: - Lock Screen Wallpaper

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
        // Particle overlay is managed by the view layer
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

        Task {
            do {
                let fps = config.frameRateLimit == .unlimited ? 60 : config.frameRateLimit.rawValue
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
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
    func advancePlaylist(for screen: Screen) {
        guard let config = configRepo.get(for: screen.id),
              let bookmarks = config.playlistBookmarks,
              !bookmarks.isEmpty else { return }

        // Pick next bookmark (random if shuffle, else sequential round-robin)
        let nextBookmark: Data
        if config.shufflePlaylist {
            nextBookmark = bookmarks.randomElement() ?? bookmarks[0]
        } else {
            // Find the current video's index in the playlist, advance to next
            let currentIndex = bookmarks.firstIndex(of: config.videoBookmarkData) ?? -1
            let nextIndex = (currentIndex + 1) % bookmarks.count
            nextBookmark = bookmarks[nextIndex]
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: nextBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        setVideo(url: url, bookmarkData: nextBookmark, for: screen)
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

    /// Periodically checks all screens for schedule-based wallpaper changes.
    func startScheduleMonitoring() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self = self else { return }
                for screen in self.screens {
                    self.checkAndApplySchedule(for: screen)
                }
            }
        }
    }

    nonisolated deinit {}
}
