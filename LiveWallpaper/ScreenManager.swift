import SwiftUI
import Combine
import AVKit
import os.log

// Monitors system memory usage and provides alerts when memory is low
class MemoryMonitor {
    private let memoryWarningThreshold: Double = 0.85 // 85% memory usage
    
    @Published private(set) var isMemoryLow: Bool = false
    @Published private(set) var currentMemoryUsage: Double = 0.0
    
    func checkMemoryUsage() -> Bool {
        let memoryUsage = getSystemMemoryUsage()
        
        let isLow = memoryUsage > memoryWarningThreshold
        
        if isLow != isMemoryLow {
            isMemoryLow = isLow
            if isLow {
                Logger.warning("System memory usage is high: \(Int(memoryUsage * 100))%", category: .memory)
            }
        }
        
        return isLow
    }
    
    // Get the actual system memory usage percentage
    func getSystemMemoryUsage() -> Double {
        var pageSize: vm_size_t = 0
        let hostPort = mach_host_self()
        var host_size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var vmStats = vm_statistics64_data_t()
        
        host_page_size(hostPort, &pageSize)
        
        let status = withUnsafeMutablePointer(to: &vmStats) { vmStatsPointer in
            vmStatsPointer.withMemoryRebound(to: integer_t.self, capacity: Int(host_size)) { pointer in
                host_statistics64(hostPort, HOST_VM_INFO64, pointer, &host_size)
            }
        }
        
        guard status == KERN_SUCCESS else {
            Logger.error("Failed to get memory statistics", category: .memory)
            return 0.0
        }
        
        let active = Double(vmStats.active_count) * Double(pageSize)
        let wired = Double(vmStats.wire_count) * Double(pageSize)
        let compressed = Double(vmStats.compressor_page_count) * Double(pageSize)
        
        let used = active + wired + compressed
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        
        return used / total
    }
    
    private func formatByteSize(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.0f KB", kb)
        }
    }
    
    // Get system memory usage formatted as a string
    func getFormattedMemoryUsage() -> String {
        return "\(Int(currentMemoryUsage * 100))%"
    }
}

// Represents frame rate limitation options
enum FrameRateLimit: Int, CaseIterable, Identifiable, Codable {
    case fps30 = 30
    case fps60 = 60
    case unlimited = 0
    
    var id: Int { rawValue }
    
    var description: String {
        switch self {
        case .fps30: return "30 FPS"
        case .fps60: return "60 FPS"
        case .unlimited: return "Unlimited"
        }
    }
    
    var iconName: String {
        switch self {
        case .fps30: return "tortoise"
        case .fps60: return "hare"
        case .unlimited: return "infinity"
        }
    }
    
    // Calculate the effective limit taking into account both the video's native frame rate and the screen refresh rate
    func getEffectiveLimit(videoFrameRate: Double, screenRefreshRate: Double) -> Float {
        // Handle unlimited case
        if self == .unlimited {
            // When unlimited is selected, respect screen refresh rate as the maximum
            // to avoid wasting GPU resources on frames that won't be visible
            if screenRefreshRate > 0 && videoFrameRate > screenRefreshRate {
                return Float(screenRefreshRate)
            }
            return 0 // No limit (will use video's native frame rate)
        }
        
        // Get the raw limit value
        let rawLimit = Float(self.rawValue)
        
        // If screen refresh rate is lower than the selected limit, cap at screen refresh rate
        if screenRefreshRate > 0 && screenRefreshRate < Double(rawLimit) {
            return Float(screenRefreshRate)
        }
        
        // If original frame rate is lower than the limit, no need to limit
        if videoFrameRate > 0 && videoFrameRate < Double(rawLimit) {
            return 0 // No limit needed (already below threshold)
        }
        
        // Apply the selected limit
        return rawLimit
    }
}

// Manages video playback on multiple screens
final class ScreenManager: ObservableObject {
    // MARK: - Properties
    
    // Thread-safe access to screens array
    private let screensLock = NSLock()
    private var _screens: [Screen] = []
    
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: Error?
    
    var screens: [Screen] {
        get {
            screensLock.lock()
            defer { screensLock.unlock() }
            return _screens
        }
        set {
            screensLock.lock()
            _screens = newValue
            screensLock.unlock()
            // Trigger UI updates whenever screens array changes
            objectWillChange.send()
        }
    }
    
    private var cleanupTasks: Set<AnyCancellable> = []
    private let configLock = NSLock()
    private var configurationCache: [CGDirectDisplayID: ScreenConfiguration] = [:]
    private let powerMonitor: PowerMonitor = .shared
    private let memoryMonitor = MemoryMonitor()
    private var lastAppliedConfigHashes: [CGDirectDisplayID: Int] = [:]
    private var configUpdateLock = NSLock()
    private let playbackStateSubject = CurrentValueSubject<Bool, Never>(false)

    // MARK: - Initialization
    init() {
        Logger.notice("ScreenManager initializing", category: .screenManager)
        setupPowerMonitoring()
        setupScreenObservers()
        setupMemoryMonitoring()
        
        // Add notification observer for video player playback state changes
        NotificationCenter.default.publisher(for: WallpaperVideoPlayer.didChangePlaybackStateNotification)
            .sink { [weak self] _ in
                self?.updatePlaybackState()
            }
            .store(in: &cleanupTasks)
        
        refreshScreens()
        loadSavedConfigurations()
        Logger.notice("ScreenManager initialization complete", category: .screenManager)
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
        Logger.debug("Setting up power monitoring", category: .screenManager)
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
        Logger.debug("Setting up screen change observers", category: .screenManager)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
        // Use a more aggressive throttling for intensive screen changes
            .throttle(for: .seconds(1.0), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                Logger.info("Screen parameters changed, refreshing screens", category: .screenManager)
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
        Logger.debug("Setting up memory monitoring", category: .screenManager)
        // Check memory usage periodically
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                
                // Check current memory usage
                if self.memoryMonitor.checkMemoryUsage() {
                    self.handleLowMemory()
                }
            }
            .store(in: &cleanupTasks)
    }
    
    // MARK: - Screen Management
    func refreshScreens() {
        Logger.functionStart(category: .screenManager)
        let timer = PerformanceTimer(description: "Screen refresh", category: .screenManager)
        
        isLoading = true
        
        // Get all current screens from system
        let newScreens = NSScreen.screens.map { Screen(nsScreen: $0) }
        Logger.screensDetected(newScreens.count)
        
        // Thread-safe access to screen IDs
        screensLock.lock()
        let oldScreenIDs = Set(_screens.map(\.id))
        screensLock.unlock()
        
        let newScreenIDs = Set(newScreens.map(\.id))
        
        // Clean up removed screens
        for screenID in oldScreenIDs.subtracting(newScreenIDs) {
            screensLock.lock()
            let screenToCleanup = _screens.first(where: { $0.id == screenID })
            screensLock.unlock()
            
            if let screen = screenToCleanup {
                Logger.info("Cleaning up removed screen \(screenID)", category: .screenManager)
                cleanupScreen(screen)
            }
            
            // Also remove from last applied configuration cache
            configUpdateLock.lock()
            lastAppliedConfigHashes.removeValue(forKey: screenID)
            configUpdateLock.unlock()
        }
        
        // Thread-safe update of screens array
        screensLock.lock()
        _screens = newScreens
        screensLock.unlock()
        
        timer.checkpoint("Screens mapped")
        
        // Configure newly added screens
        for screen in newScreens where newScreenIDs.subtracting(oldScreenIDs).contains(screen.id) {
            Logger.info("Configuring new screen \(screen.id)", category: .screenManager)
            loadConfigurationForScreen(screen)
        }
        
        // Finish loading
        isLoading = false
        objectWillChange.send()
        
        // Update playback state
        updatePlaybackState()
        timer.checkpoint("Playback state updated")
        
        // Post notification that screens were refreshed
        NotificationCenter.default.post(name: .init("ScreensRefreshed"), object: nil)
        Logger.functionEnd(category: .screenManager)
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
        configLock.lock()
        configurationCache.removeValue(forKey: screen.id)
        configLock.unlock()
        
        // Notify UI of change
        objectWillChange.send()
    }
    
    private func cleanupScreen(_ screen: Screen) {
        Logger.debug("Cleaning up screen \(screen.id)", category: .screenManager)
        screen.videoPlayer?.cleanup()
        screen.previewPlayer?.pause()
        screen.previewPlayer = nil
    }
    
    // MARK: - Configuration Management
    private func loadSavedConfigurations() {
        Logger.debug("Loading saved configurations", category: .screenManager)
        let configurations = SettingsManager.shared.loadConfigurations()
        
        for configuration in configurations {
            cacheConfiguration(configuration)
            
            // Thread-safe access to screens
            screensLock.lock()
            let screenToLoad = _screens.first(where: { $0.id == configuration.screenID })
            screensLock.unlock()
            
            if let screen = screenToLoad {
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
        Logger.info("Setting video for screen \(screen.id): \(url.lastPathComponent)", category: .screenManager)
        
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
                Logger.debug("Same video URL detected, updating existing configuration", category: .screenManager)
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
        
        cacheConfiguration(configuration)
        SettingsManager.shared.saveConfiguration(configuration)
        Logger.debug("New configuration created and saved for screen \(screen.id)", category: .screenManager)
        
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
                        Logger.debug("Video asset loaded, setting up playback", category: .screenManager)
                        self?.setupVideoPlayback(asset: asset, screen: screen)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        Logger.error("Failed to setup video: \(error.localizedDescription)", category: .screenManager)
                        self?.lastError = error
                    }
                }
            }
        } else {
            lastError = NSError(domain: "ScreenManager", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to save video configuration."
            ])
            Logger.error("Failed to save video configuration for screen \(screen.id)", category: .screenManager)
        }
    }
    
    private func updateExistingVideoConfiguration(_ existingConfig: ScreenConfiguration, url: URL, bookmarkData: Data, for screen: Screen) {
        // Just update the bookmark data and preserve other settings
        let updatedConfig = ScreenConfiguration(
            screenID: existingConfig.screenID,
            videoBookmarkData: bookmarkData,
            playbackSpeed: existingConfig.playbackSpeed,
            fitMode: existingConfig.fitMode,
            pauseOnBattery: existingConfig.pauseOnBattery,
            frameRateLimit: existingConfig.frameRateLimit
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
                        pauseOnBattery: configuration.pauseOnBattery,
                        frameRateLimit: configuration.frameRateLimit
                    )
                    
                    cacheConfiguration(updatedConfig)
                    SettingsManager.shared.saveConfiguration(updatedConfig)
                } catch {
                    Logger.error("Failed to update stale bookmark: \(error.localizedDescription)", category: .fileAccess)
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
                        Logger.debug("Limiting frame rate to \(limit) FPS for screen \(screen.id)", category: .videoPlayer)
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
                            Logger.debug("Limiting frame rate to \(limit) FPS for screen \(screen.id)", category: .videoPlayer)
                            player.setFrameRateLimit(limit)
                        }
                    }
                }
            }
            
            // Only notify of changes if something important changed
            if needsNewPlayer {
                objectWillChange.send()
            }
            
        } catch {
            lastError = error
            Logger.error("Failed to apply configuration: \(error.localizedDescription)", category: .screenManager)
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
        
        // Thread-safe update of screen properties
        screensLock.lock()
        if let index = _screens.firstIndex(where: { $0.id == screen.id }) {
            _screens[index].videoPlayer = player
            _screens[index].previewPlayer = previewPlayer
            
            // Check if we should pause based on power state
            let shouldPause = powerMonitor.currentPowerSource.isOnBattery &&
            SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery
            
            if shouldPause {
                player.pause()
            } else {
                // Delay playback to ensure proper initialization
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    player.play()
                    previewPlayer.play()
                    
                    // Update playback state after playback begins
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.updatePlaybackState()
                    }
                }
            }
            
            screensLock.unlock()
            
            // Apply frame rate limit if configured
            if player.videoFrameRate > 0,
               let frameRateLimit = configuration?.frameRateLimit {
                
                // Delay frame rate limit application slightly to ensure video properties are loaded
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.applyFrameRateLimit(frameRateLimit, to: screen)
                }
            }
            
            // Notify observers of the change immediately
            objectWillChange.send()
            Logger.info("Video player setup complete for screen \(screen.id)", category: .screenManager)
        } else {
            screensLock.unlock()
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
        // Thread-safe access to screens
        screensLock.lock()
        let isAnyPlaying = _screens.contains { $0.videoPlayer?.isPlaying ?? false }
        screensLock.unlock()
        
        // Only publish if the state actually changed
        if playbackStateSubject.value != isAnyPlaying {
            Logger.debug("Global playback state changed to: \(isAnyPlaying ? "playing" : "paused")", category: .videoPlayer)
            playbackStateSubject.send(isAnyPlaying)
        }
    }
    
    func togglePlayback() {
        // Thread-safe check if any videos are playing
        screensLock.lock()
        let isAnyPlaying = _screens.contains { $0.videoPlayer?.isPlaying ?? false }
        screensLock.unlock()
        
        Logger.info("Toggling global playback: \(isAnyPlaying ? "pausing" : "playing") all videos", category: .videoPlayer)
        
        // Toggle playback based on current state
        screensLock.lock()
        for screen in _screens {
            if let player = screen.videoPlayer {
                if isAnyPlaying {
                    player.pause()
                } else {
                    player.play()
                }
            }
        }
        screensLock.unlock()
        
        // Update the playback state
        updatePlaybackState()
    }
    
    // MARK: - Power Management
    private func handlePowerStateChange(_ powerSource: PowerMonitor.PowerSource) {
        Logger.info("Handling power state change", category: .powerMonitor)
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let isOnBattery = powerSource.isOnBattery
        
        // Batch updates to avoid multiple UI updates
        var updatedScreens = false
        
        // Thread-safe access to screens
        screensLock.lock()
        for screen in _screens {
            guard let player = screen.videoPlayer else {
                continue
            }
            
            let configuration = getCachedConfiguration(for: screen.id)
            let shouldPause = (globalSettings.globalPauseOnBattery || configuration?.pauseOnBattery == true) && isOnBattery
            
            if let batteryLevel = globalSettings.minimumBatteryLevel, isOnBattery {
                if case .battery(let level) = powerSource, level < batteryLevel {
                    // Force pause if battery is below the threshold
                    if player.isPlaying {
                        Logger.debug("Pausing screen \(screen.id) due to low battery level (\(Int(level * 100))%)", category: .powerMonitor)
                        player.pause()
                        updatedScreens = true
                    }
                    continue
                }
            }
            
            let currentlyPlaying = player.isPlaying
            if shouldPause && currentlyPlaying {
                Logger.debug("Pausing screen \(screen.id) due to battery power", category: .powerMonitor)
                player.pause()
                updatedScreens = true
            } else if !shouldPause && !currentlyPlaying && !isOnBattery {
                Logger.debug("Resuming screen \(screen.id) due to external power", category: .powerMonitor)
                player.play()
                updatedScreens = true
            }
        }
        screensLock.unlock()
        
        if updatedScreens {
            objectWillChange.send()
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
        
        // Thread-safe access to screens
        screensLock.lock()
        
        // If memory is low, pause all videos that aren't visible or active
        for screen in _screens {
            if let player = screen.videoPlayer, player.isPlaying {
                // Check if this screen is currently visible/active
                let isActive = NSScreen.screens.contains { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == screen.id }
                
                if !isActive {
                    Logger.debug("Pausing background video on screen \(screen.id) to conserve memory", category: .memory)
                    player.pause()
                }
            }
        }
        
        screensLock.unlock()
        
        // Release unused resources
        autoreleasepool {
            // Clear any image caches if needed
            Logger.debug("Clearing cached resources to free memory", category: .memory)
        }
    }
    
    // MARK: - System Events
    private func handleSystemWake() {
        Logger.info("System wake detected", category: .lifecycle)
        Task { @MainActor in
            refreshScreens()
            powerMonitor.refreshPowerStatus()
            handlePowerStateChange(powerMonitor.currentPowerSource)
            Logger.debug("System wake handling complete", category: .lifecycle)
        }
    }
    
    // MARK: - Public Interface
    // Reload the video for a specific screen
    func reloadVideoForScreen(_ screen: Screen) {
        Logger.info("Manually reloading video for screen \(screen.id)", category: .screenManager)
        if let configuration = getCachedConfiguration(for: screen.id) {
            applyConfiguration(configuration, to: screen, preservingState: true)
        }
    }
    
    // Update the playback speed for a screen
    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        guard var configuration = getCachedConfiguration(for: screen.id) else { return }
        
        // Skip update if value hasn't changed
        guard speed != configuration.playbackSpeed else { return }
        
        Logger.debug("Updating playback speed to \(speed)x for screen \(screen.id)", category: .videoPlayer)
        
        configuration = ScreenConfiguration(
            screenID: configuration.screenID,
            videoBookmarkData: configuration.videoBookmarkData,
            playbackSpeed: speed,
            fitMode: configuration.fitMode,
            pauseOnBattery: configuration.pauseOnBattery,
            frameRateLimit: configuration.frameRateLimit
        )
        
        cacheConfiguration(configuration)
        SettingsManager.shared.saveConfiguration(configuration)
        screen.videoPlayer?.setPlaybackSpeed(speed)
    }
    
    // Update the fit mode for a screen
    func updateFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard var configuration = getCachedConfiguration(for: screen.id) else { return }
        
        // Skip update if value hasn't changed
        guard fitMode != configuration.fitMode else { return }
        
        Logger.debug("Updating fit mode to \(fitMode.rawValue) for screen \(screen.id)", category: .videoPlayer)
        
        configuration = ScreenConfiguration(
            screenID: configuration.screenID,
            videoBookmarkData: configuration.videoBookmarkData,
            playbackSpeed: configuration.playbackSpeed,
            fitMode: fitMode,
            pauseOnBattery: configuration.pauseOnBattery,
            frameRateLimit: configuration.frameRateLimit
        )
        
        cacheConfiguration(configuration)
        SettingsManager.shared.saveConfiguration(configuration)
        screen.videoPlayer?.setVideoFitMode(fitMode)
    }
    
    // Update the frame rate limit for a screen
    func updateFrameRateLimit(_ frameRateLimit: FrameRateLimit, for screen: Screen) {
        guard var configuration = getCachedConfiguration(for: screen.id) else {
            Logger.warning("Cannot update frame rate limit: No configuration found for screen \(screen.id)", category: .videoPlayer)
            return
        }
        
        // Skip update if value hasn't changed
        guard frameRateLimit != configuration.frameRateLimit else { return }
        
        Logger.debug("Updating frame rate limit to \(frameRateLimit.description) for screen \(screen.id)", category: .videoPlayer)
        
        // Create updated configuration
        configuration = ScreenConfiguration(
            screenID: configuration.screenID,
            videoBookmarkData: configuration.videoBookmarkData,
            playbackSpeed: configuration.playbackSpeed,
            fitMode: configuration.fitMode,
            pauseOnBattery: configuration.pauseOnBattery,
            frameRateLimit: frameRateLimit
        )
        
        // Save configuration
        cacheConfiguration(configuration)
        SettingsManager.shared.saveConfiguration(configuration)
        
        // Apply the frame rate limit to the player
        applyFrameRateLimit(frameRateLimit, to: screen)
    }
    
    // Apply frame rate limit to a screen's video player
    private func applyFrameRateLimit(_ frameRateLimit: FrameRateLimit, to screen: Screen) {
        guard let player = screen.videoPlayer, player.videoFrameRate > 0 else {
            Logger.debug("Cannot apply frame rate limit: No active player with valid frame rate", category: .videoPlayer)
            return
        }
        
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
    
    // Apply a visual filter to a screen
    func applyFilter(_ filterName: String?, for screen: Screen) {
        guard var configuration = getCachedConfiguration(for: screen.id) else { return }
        
        let _ = filterName != nil ? [filterName!] : []
        
        configuration = ScreenConfiguration(
            screenID: configuration.screenID,
            videoBookmarkData: configuration.videoBookmarkData,
            playbackSpeed: configuration.playbackSpeed,
            fitMode: configuration.fitMode,
            pauseOnBattery: configuration.pauseOnBattery,
            frameRateLimit: configuration.frameRateLimit
        )
        
        cacheConfiguration(configuration)
        SettingsManager.shared.saveConfiguration(configuration)
    }
    
    // Get the saved configuration for a screen
    func getConfiguration(for screen: Screen) -> ScreenConfiguration? {
        return getCachedConfiguration(for: screen.id) ?? SettingsManager.shared.getConfiguration(for: screen.id)
    }
    
    // Update power settings for a screen
    func updatePowerSettings(pauseOnBattery: Bool, for screen: Screen) {
        guard var configuration = getConfiguration(for: screen) else { return }
        
        // Skip update if value hasn't changed
        guard pauseOnBattery != configuration.pauseOnBattery else { return }
        
        Logger.debug("Updating power settings (pauseOnBattery: \(pauseOnBattery)) for screen \(screen.id)", category: .powerMonitor)
        
        configuration = ScreenConfiguration(
            screenID: configuration.screenID,
            videoBookmarkData: configuration.videoBookmarkData,
            playbackSpeed: configuration.playbackSpeed,
            fitMode: configuration.fitMode,
            pauseOnBattery: pauseOnBattery,
            frameRateLimit: configuration.frameRateLimit
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
    
    // Validate all saved configurations
    func validateAllConfigurations() -> (valid: Int, invalid: Int) {
        Logger.debug("Validating all screen configurations", category: .settings)
        let screenIDs = getAllCachedScreenIDs()
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
        let timer = PerformanceTimer(description: "Reload all screens", category: .performance)
        
        // First invalidate cached bookmark data to force a fresh reload
        for screenID in getAllCachedScreenIDs() {
            if !SettingsManager.shared.validateConfiguration(for: screenID) {
                Logger.warning("Removing invalid configuration for screen \(screenID)", category: .settings)
                removeCachedConfiguration(for: screenID)
            }
        }
        
        timer.checkpoint("Configuration validation")
        
        // Thread-safe access to screens
        screensLock.lock()
        let currentScreens = _screens
        screensLock.unlock()
        
        // Then reload all screens
        for screen in currentScreens {
            if let configuration = SettingsManager.shared.getConfiguration(for: screen.id) {
                cacheConfiguration(configuration)
                applyConfiguration(configuration, to: screen, preservingState: false)
            }
        }
        
        timer.checkpoint("Applied configurations")
        Logger.notice("All screens reloaded", category: .screenManager)
    }
    
    // MARK: - Helper Methods
    
    // Get screen refresh rate for a specific display ID
    func getScreenRefreshRate(for screenID: CGDirectDisplayID) -> Int {
        // Use CGDisplayMode to get accurate refresh rate
        guard let mode = CGDisplayCopyDisplayMode(screenID) else {
            Logger.warning("Could not get display mode for screen \(screenID), using default 60Hz", category: .screenManager)
            return 60 // Default to 60Hz if we can't determine
        }
        
        let refreshRate = mode.refreshRate
        if refreshRate <= 0 {
            Logger.warning("Invalid refresh rate (\(refreshRate)) for screen \(screenID), using default 60Hz", category: .screenManager)
            return 60 // Handle invalid values
        }
        
        Logger.debug("Detected refresh rate: \(Int(refreshRate))Hz for screen \(screenID)", category: .screenManager)
        return Int(refreshRate)
    }
    
    func applyInitialFrameRateLimit(for screen: Screen) {
        guard let config = getCachedConfiguration(for: screen.id) else { return }
        
        applyFrameRateLimit(config.frameRateLimit, to: screen)
    }
    
    // MARK: - Cleanup
    deinit {
        Logger.debug("ScreenManager deinitializing", category: .lifecycle)
        cleanupTasks.removeAll()
        screensLock.lock()
        for screen in _screens {
            cleanupScreen(screen)
        }
        screensLock.unlock()
    }
}
