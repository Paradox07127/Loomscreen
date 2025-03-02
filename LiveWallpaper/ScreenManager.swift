import SwiftUI
import Combine
import AVKit

/// Monitors system memory usage and provides alerts when memory is low
class MemoryMonitor {
    private let memoryWarningThreshold: Double = 0.85 // 85% memory usage
    
    @Published private(set) var isMemoryLow: Bool = false
    
    func checkMemoryUsage() -> Bool {
        // Simplified implementation - in a real app, we would use proper memory pressure APIs
        let memoryUsage = getSystemMemoryUsage()
        let isLow = memoryUsage > memoryWarningThreshold
        
        if isLow != isMemoryLow {
            isMemoryLow = isLow
        }
        
        return isLow
    }
    
    private func getSystemMemoryUsage() -> Double {
        // In a real implementation, this would use host_statistics64 to get actual memory usage
        // For now, returning a placeholder value
        return ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 100) / 100
    }
}

/// Manages video playback on multiple screens
final class ScreenManager: ObservableObject {
    // MARK: - Properties
    @Published private(set) var screens: [Screen] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: Error?
    
    private var cleanupTasks: Set<AnyCancellable> = []
    private let configLock = NSLock()
    private var configurationCache: [CGDirectDisplayID: ScreenConfiguration] = [:]
    private let powerMonitor: PowerMonitor = .shared
    private let memoryMonitor = MemoryMonitor()
    
    // MARK: - Initialization
    init() {
        setupPowerMonitoring()
        setupScreenObservers()
        setupMemoryMonitoring()
        refreshScreens()
        loadSavedConfigurations()
    }
    
    // MARK: - Configuration Cache Management
    private func cacheConfiguration(_ configuration: ScreenConfiguration) {
        configLock.lock()
        defer { configLock.unlock() }
        configurationCache[configuration.screenID] = configuration
    }
    
    private func getCachedConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configLock.lock()
        defer { configLock.unlock() }
        return configurationCache[screenID]
    }
    
    private func removeCachedConfiguration(for screenID: CGDirectDisplayID) {
        configLock.lock()
        defer { configLock.unlock() }
        configurationCache.removeValue(forKey: screenID)
    }
    
    private func getAllCachedScreenIDs() -> [CGDirectDisplayID] {
        configLock.lock()
        defer { configLock.unlock() }
        return Array(configurationCache.keys)
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
            .sink { [weak self] _ in
                self?.refreshScreens()
            }
            .store(in: &cleanupTasks)
        
        NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.handleSystemWake()
            }
            .store(in: &cleanupTasks)
    }
    
    private func setupMemoryMonitoring() {
        // Check memory usage periodically
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                if self?.memoryMonitor.checkMemoryUsage() == true {
                    self?.handleLowMemory()
                }
            }
            .store(in: &cleanupTasks)
    }
    
    // MARK: - Screen Management
    // Modified refreshScreens method to include performance optimizations
    func refreshScreens() {
        isLoading = true
        
        // Get all current screens from system
        let newScreens = NSScreen.screens.map { Screen(nsScreen: $0) }
        let oldScreenIDs = Set(screens.map(\.id))
        let newScreenIDs = Set(newScreens.map(\.id))
        
        // Clean up removed screens
        for screenID in oldScreenIDs.subtracting(newScreenIDs) {
            if let screen = screens.first(where: { $0.id == screenID }) {
                cleanupScreen(screen)
            }
            
            // Also remove from last applied configuration cache
            configUpdateLock.lock()
            lastAppliedConfigHashes.removeValue(forKey: screenID)
            configUpdateLock.unlock()
        }
        
        screens = newScreens
        
        // Configure newly added screens
        for screen in screens where newScreenIDs.subtracting(oldScreenIDs).contains(screen.id) {
            loadConfigurationForScreen(screen)
        }
        
        // Finish loading
        isLoading = false
        objectWillChange.send()
    }
    
    private func cleanupScreen(_ screen: Screen) {
        screen.videoPlayer?.cleanup()
        screen.previewPlayer?.pause()
        screen.previewPlayer = nil
    }
    
    // MARK: - Configuration Management
    private func loadSavedConfigurations() {
        let configurations = SettingsManager.shared.loadConfigurations()
        
        for configuration in configurations {
            cacheConfiguration(configuration)
            
            if let screen = screens.first(where: { $0.id == configuration.screenID }) {
                loadConfigurationForScreen(screen)
            }
        }
    }
    
    private func loadConfigurationForScreen(_ screen: Screen) {
        if let cachedConfig = getCachedConfiguration(for: screen.id) {
            applyConfiguration(cachedConfig, to: screen)
        } else if let savedConfig = SettingsManager.shared.getConfiguration(for: screen.id) {
            cacheConfiguration(savedConfig)
            applyConfiguration(savedConfig, to: screen)
        }
    }
    
    // MARK: - Video Management
    func setVideo(url: URL, bookmarkData: Data, for screen: Screen) {
        // Check if we're just updating the same video to avoid unnecessary reloads
        if let existingConfig = getCachedConfiguration(for: screen.id) {
            var isStale = false
            if let existingURL = try? URL(
                resolvingBookmarkData: existingConfig.videoBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), existingURL == url {
                // Same URL, just update configurations if needed
                updateExistingVideoConfiguration(existingConfig, url: url, bookmarkData: bookmarkData, for: screen)
                return
            }
        }
        
        // Otherwise, create a new configuration
        let configuration = ScreenConfiguration(
            screenID: screen.id,
            videoBookmarkData: bookmarkData,
            playbackSpeed: 1.0,
            fitMode: .aspectFill,
            pauseOnBattery: SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery
        )
        
        cacheConfiguration(configuration)
        SettingsManager.shared.saveConfiguration(configuration)
        
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
                    await MainActor.run { [weak self] in
                        self?.lastError = error
                    }
                }
            }
        } else {
            lastError = NSError(domain: "ScreenManager", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to save video configuration."
            ])
        }
    }
    
    private func updateExistingVideoConfiguration(_ existingConfig: ScreenConfiguration, url: URL, bookmarkData: Data, for screen: Screen) {
        // Just update the bookmark data and preserve other settings
        let updatedConfig = ScreenConfiguration(
            screenID: existingConfig.screenID,
            videoBookmarkData: bookmarkData,
            playbackSpeed: existingConfig.playbackSpeed,
            fitMode: existingConfig.fitMode,
            pauseOnBattery: existingConfig.pauseOnBattery
        )
        
        cacheConfiguration(updatedConfig)
        SettingsManager.shared.saveConfiguration(updatedConfig)
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
                    
                    let updatedConfig = ScreenConfiguration(
                        screenID: configuration.screenID,
                        videoBookmarkData: updatedBookmarkData,
                        playbackSpeed: configuration.playbackSpeed,
                        fitMode: configuration.fitMode,
                        pauseOnBattery: configuration.pauseOnBattery
                    )
                    
                    cacheConfiguration(updatedConfig)
                    SettingsManager.shared.saveConfiguration(updatedConfig)
                } catch {
                    // Log but continue with existing configuration
                    print("Failed to update stale bookmark: \(error.localizedDescription)")
                }
            }
            
            // Check if we need to update the player at all
            let needsNewPlayer = screen.videoPlayer == nil
            
            // Save current playback position if preserving state
            let currentTime = preservingState ? screen.videoPlayer?.player?.currentTime() : .zero
            let wasPlaying = screen.videoPlayer?.isPlaying ?? false
            
            if needsNewPlayer {
                // Clean up existing player
                screen.videoPlayer?.cleanup()
                
                // Create new player with the configuration settings
                let player = WallpaperVideoPlayer(
                    url: url,
                    frame: screen.frame,
                    fitMode: configuration.fitMode
                )
                screen.videoPlayer = player
                
                // Apply settings
                player.setPlaybackSpeed(configuration.playbackSpeed)
                
                // Restore playback position if needed
                if let currentTime = currentTime {
                    player.player?.seek(to: currentTime)
                }
                
                // Check if we should pause based on power state
                let shouldPause = powerMonitor.currentPowerSource.isOnBattery &&
                (SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery || configuration.pauseOnBattery)
                
                if shouldPause {
                    player.pause()
                } else if wasPlaying {
                    // Small delay to ensure proper initialization
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        player.play()
                    }
                }
            } else {
                // Just update existing player settings if needed
                if let player = screen.videoPlayer {
                    // No need to update playback speed if it hasn't changed
                    if abs(Float(configuration.playbackSpeed) - (player.player?.rate ?? 1.0)) > 0.01 {
                        player.setPlaybackSpeed(configuration.playbackSpeed)
                    }
                }
            }
            
            // Only notify of changes if something important changed
            if needsNewPlayer {
                objectWillChange.send()
            }
            
        } catch {
            lastError = error
        }
    }
    
    private func setupVideoPlayback(asset: AVURLAsset, screen: Screen) {
        cleanupScreen(screen)
        
        // Create preview player for settings UI
        let previewPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        previewPlayer.volume = 0
        
        // Get configuration
        let configuration = getCachedConfiguration(for: screen.id)
        
        // Create wallpaper player
        let player = WallpaperVideoPlayer(
            url: asset.url,
            frame: screen.frame,
            fitMode: configuration?.fitMode ?? .aspectFill
        )
        
        // Update screen
        if let index = screens.firstIndex(where: { $0.id == screen.id }) {
            screens[index].videoPlayer = player
            screens[index].previewPlayer = previewPlayer
        }
        
        // Check if we should pause based on power state
        let shouldPause = powerMonitor.currentPowerSource.isOnBattery &&
        SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery
        
        if shouldPause {
            player.pause()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                player.play()
                previewPlayer.play()
            }
        }
        
        objectWillChange.send()
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
            
            let configuration = getCachedConfiguration(for: screen.id)
            let shouldPause = (globalSettings.globalPauseOnBattery || configuration?.pauseOnBattery == true) && isOnBattery
            
            let currentlyPlaying = player.isPlaying
            if shouldPause && currentlyPlaying {
                player.pause()
                updatedScreens = true
            } else if !shouldPause && !currentlyPlaying && !isOnBattery {
                player.play()
                updatedScreens = true
            }
        }
        
        if updatedScreens {
            objectWillChange.send()
        }
    }
    
    func handleGlobalPauseOnBatteryChange(_ pauseOnBattery: Bool) {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.globalPauseOnBattery = pauseOnBattery
        SettingsManager.shared.saveGlobalSettings(settings)
        
        handlePowerStateChange(powerMonitor.currentPowerSource)
    }
    
    // MARK: - Memory Management
    private func handleLowMemory() {
        // If memory is low, pause all videos that aren't visible
        for screen in screens {
            if let player = screen.videoPlayer, player.isPlaying {
                // Check if this screen is currently visible/active
                let isActive = NSScreen.screens.contains { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == screen.id }
                
                if !isActive {
                    player.pause()
                }
            }
        }
    }
    
    // MARK: - System Events
    private func handleSystemWake() {
        Task { @MainActor in
            refreshScreens()
            powerMonitor.refreshPowerStatus()
            handlePowerStateChange(powerMonitor.currentPowerSource)
        }
    }
    
    // MARK: - Public Interface
    /// Reload the video for a specific screen
    func reloadVideoForScreen(_ screen: Screen) {
        if let configuration = getCachedConfiguration(for: screen.id) {
            applyConfiguration(configuration, to: screen, preservingState: true)
        }
    }
    
    // Update the playback speed for a screen
    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        guard var configuration = getCachedConfiguration(for: screen.id) else { return }
        
        // Skip update if value hasn't changed
        guard speed != configuration.playbackSpeed else { return }
        
        configuration = ScreenConfiguration(
            screenID: configuration.screenID,
            videoBookmarkData: configuration.videoBookmarkData,
            playbackSpeed: speed,
            fitMode: configuration.fitMode,
            pauseOnBattery: configuration.pauseOnBattery
        )
        
        cacheConfiguration(configuration)
        SettingsManager.shared.saveConfiguration(configuration)
        screen.videoPlayer?.setPlaybackSpeed(speed)
    }
    
    /// Update the fit mode for a screen
    func updateFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard var configuration = getCachedConfiguration(for: screen.id) else { return }
        
        // Skip update if value hasn't changed
        guard fitMode != configuration.fitMode else { return }
        
        configuration = ScreenConfiguration(
            screenID: configuration.screenID,
            videoBookmarkData: configuration.videoBookmarkData,
            playbackSpeed: configuration.playbackSpeed,
            fitMode: fitMode,
            pauseOnBattery: configuration.pauseOnBattery
        )
        
        cacheConfiguration(configuration)
        SettingsManager.shared.saveConfiguration(configuration)
        screen.videoPlayer?.setVideoFitMode(fitMode)
    }
    
    /// Apply a visual filter to a screen
    func applyFilter(_ filterName: String?, for screen: Screen) {
        guard var configuration = getCachedConfiguration(for: screen.id) else { return }
        
        let _ = filterName != nil ? [filterName!] : []
        
        configuration = ScreenConfiguration(
            screenID: configuration.screenID,
            videoBookmarkData: configuration.videoBookmarkData,
            playbackSpeed: configuration.playbackSpeed,
            fitMode: configuration.fitMode,
            pauseOnBattery: configuration.pauseOnBattery
        )
        
        cacheConfiguration(configuration)
        SettingsManager.shared.saveConfiguration(configuration)
    }
    
    /// Get the saved configuration for a screen
    func getConfiguration(for screen: Screen) -> ScreenConfiguration? {
        return getCachedConfiguration(for: screen.id) ?? SettingsManager.shared.getConfiguration(for: screen.id)
    }
    
    /// Update power settings for a screen
    func updatePowerSettings(pauseOnBattery: Bool, for screen: Screen) {
        guard var configuration = getConfiguration(for: screen) else { return }
        
        // Skip update if value hasn't changed
        guard pauseOnBattery != configuration.pauseOnBattery else { return }
        
        configuration = ScreenConfiguration(
            screenID: configuration.screenID,
            videoBookmarkData: configuration.videoBookmarkData,
            playbackSpeed: configuration.playbackSpeed,
            fitMode: configuration.fitMode,
            pauseOnBattery: pauseOnBattery
        )
        
        cacheConfiguration(configuration)
        SettingsManager.shared.saveConfiguration(configuration)
        
        // Apply the new setting immediately if on battery
        if powerMonitor.currentPowerSource.isOnBattery && pauseOnBattery {
            screen.videoPlayer?.pause()
        } else if powerMonitor.currentPowerSource.isOnBattery == false && !pauseOnBattery {
            screen.videoPlayer?.play()
        }
    }
    
    /// Validate all saved configurations
    func validateAllConfigurations() -> (valid: Int, invalid: Int) {
        let screenIDs = getAllCachedScreenIDs()
        var validConfigCount = 0
        var invalidConfigCount = 0
        
        for screenID in screenIDs {
            if SettingsManager.shared.validateConfiguration(for: screenID) {
                validConfigCount += 1
            } else {
                invalidConfigCount += 1
            }
        }
        
        return (validConfigCount, invalidConfigCount)
    }
    
    /// Reload all screens
    func reloadAllScreens() {
        // First invalidate cached bookmark data to force a fresh reload
        for screenID in getAllCachedScreenIDs() {
            if !SettingsManager.shared.validateConfiguration(for: screenID) {
                removeCachedConfiguration(for: screenID)
            }
        }
        
        // Then reload all screens
        for screen in screens {
            if let configuration = SettingsManager.shared.getConfiguration(for: screen.id) {
                cacheConfiguration(configuration)
                applyConfiguration(configuration, to: screen, preservingState: false)
            }
        }
    }
    
    // Add these properties to the ScreenManager class
    private var lastAppliedConfigHashes: [CGDirectDisplayID: Int] = [:]
    private var configUpdateLock = NSLock()
    
    // Add this method to the ScreenManager class to determine if config needs updating
    private func shouldUpdateConfiguration(_ configuration: ScreenConfiguration, for screen: Screen) -> Bool {
        configUpdateLock.lock()
        defer { configUpdateLock.unlock() }
        
        // Create a hash of the current configuration
        var hasher = Hasher()
        hasher.combine(configuration.screenID)
        hasher.combine(configuration.playbackSpeed)
        hasher.combine(configuration.fitMode)
        hasher.combine(configuration.pauseOnBattery)
        
        let configHash = hasher.finalize()
        
        // Check if this configuration is different from the last applied one
        let lastHash = lastAppliedConfigHashes[screen.id]
        let needsUpdate = lastHash == nil || lastHash != configHash
        
        // Update the last applied hash if needed
        if needsUpdate {
            lastAppliedConfigHashes[screen.id] = configHash
        }
        
        return needsUpdate
    }
    
    
    
    // Add this method to efficiently apply updates to a running video player without restarting it
    private func updateExistingPlayer(_ player: WallpaperVideoPlayer, with configuration: ScreenConfiguration) -> Bool {
        var changed = false
        
        // Update playback speed if needed
        if abs(Float(configuration.playbackSpeed) - (player.player?.rate ?? 1.0)) > 0.01 {
            player.setPlaybackSpeed(configuration.playbackSpeed)
            changed = true
        }
        
        player.setVideoFitMode(configuration.fitMode)
        
        
        return changed
    }
    
    // MARK: - Cleanup
    deinit {
        cleanupTasks.removeAll()
        for screen in screens {
            cleanupScreen(screen)
        }
    }
}
