import SwiftUI
import AVFoundation
import IOKit.ps

class ScreenManager: ObservableObject {
    @Published private(set) var screens: [Screen] = []
    private var powerMonitorToken: NSObjectProtocol?
    private var powerSourceObserver: NSObjectProtocol?
    private var screenConfigurations: [CGDirectDisplayID: (url: URL, bookmarkData: Data)] = [:]
    
    init() {
        refreshScreens()
        setupScreenObserver()
        setupPowerObserver()
        loadSavedConfigurations()
        
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        if globalSettings.globalPauseOnBattery && PowerMonitor.shared.isOnBattery {
            for screen in screens {
                screen.videoPlayer?.pause()
            }
        }
    }
    
    func refreshScreens() {
        // Store current screen states for comparison
        let oldScreenStates = Dictionary(uniqueKeysWithValues: screens.map { screen in
            (screen.id, (frame: screen.frame, scale: screen.nsScreen.backingScaleFactor))
        })
        
        let newScreens = NSScreen.screens.map { Screen(nsScreen: $0) }
        let newScreenStates = Dictionary(uniqueKeysWithValues: newScreens.map { screen in
            (screen.id, (frame: screen.frame, scale: screen.nsScreen.backingScaleFactor))
        })
        
        // Find removed screens
        let removedScreenIDs = Set(oldScreenStates.keys).subtracting(newScreenStates.keys)
        for screenID in removedScreenIDs {
            if let screen = screens.first(where: { $0.id == screenID }) {
                cleanupScreen(screen)
            }
        }
        
        // Update screens array
        screens = newScreens
        
        // Handle resolution and scale changes for existing screens
        for screen in screens {
            let oldState = oldScreenStates[screen.id]
            let newState = newScreenStates[screen.id]
            
            if oldState?.frame != newState?.frame || oldState?.scale != newState?.scale {
                // Resolution or scale has changed, reload the video
                reloadVideoForScreen(screen)
            } else if oldScreenStates[screen.id] == nil {
                // New screen, load its configuration
                loadConfigurationForScreen(screen)
            }
        }
    }
    
    private func cleanupScreen(_ screen: Screen) {
        screen.videoPlayer?.stop()
        screen.previewPlayer?.pause()
        screen.previewPlayer = nil
    }
    
    private func loadSavedConfigurations() {
        let configurations = SettingsManager.shared.loadConfigurations()
        
        for configuration in configurations {
            if let screen = screens.first(where: { $0.id == configuration.screenID }) {
                loadConfigurationForScreen(screen)
            }
        }
    }
    
    private func loadConfigurationForScreen(_ screen: Screen) {
        guard let configuration = SettingsManager.shared.getConfiguration(for: screen.id) else { return }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: configuration.videoBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if url.startAccessingSecurityScopedResource() {
                setVideo(url: url, bookmarkData: configuration.videoBookmarkData, for: screen)
                screen.videoPlayer?.setPlaybackSpeed(configuration.playbackSpeed)
                
                // If pause on battery is enabled and we're on battery, pause the video
                if configuration.pauseOnBattery && PowerMonitor.shared.isOnBattery {
                    screen.videoPlayer?.pause()
                }
                
                url.stopAccessingSecurityScopedResource()
            }
        } catch {
            print("Error loading configuration for screen \(screen.id): \(error)")
        }
    }
    
    func reloadVideoForScreen(_ screen: Screen) {
        if let config = SettingsManager.shared.getConfiguration(for: screen.id) {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: config.videoBookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                if url.startAccessingSecurityScopedResource() {
                    // Store playback state
                    let wasPlaying = screen.videoPlayer?.isPlaying ?? false
                    let currentTime = screen.videoPlayer?.player?.currentTime() ?? .zero
                    
                    // Recreate video player with new frame
                    cleanupScreen(screen)
                    
                    // Create new video player
                    let player = WallpaperVideoPlayer(
                        url: url,
                        frame: screen.frame
                    )
                    screen.videoPlayer = player
                    
                    // Restore playback state
                    player.setPlaybackSpeed(config.playbackSpeed)
                    player.player?.seek(to: currentTime)
                    
                    // Check if we should play based on power state
                    let shouldPlay = wasPlaying && (!config.pauseOnBattery || !PowerMonitor.shared.isOnBattery)
                    if shouldPlay {
                        player.play()
                    } else {
                        player.pause()
                    }
                    
                    url.stopAccessingSecurityScopedResource()
                }
            } catch {
                print("Error reloading video for screen \(screen.id): \(error)")
            }
        }
    }
    
    private func setupScreenObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    private func setupPowerObserver() {
        // Observe wake from sleep
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWakeFromSleep),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        // Observe power source changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerSourceChange),
            name: PowerMonitor.powerSourceDidChangeNotification,
            object: nil
        )
    }
    
    @objc private func handleWakeFromSleep() {
        // On wake, refresh screens and check power state
        DispatchQueue.main.async { [weak self] in
            self?.refreshScreens()
            self?.handlePowerStateChange()
        }
    }
    
    @objc private func handlePowerSourceChange() {
        handlePowerStateChange()
    }
    
    func handleGlobalPauseOnBatteryChange(_ pauseOnBattery: Bool) {
        let isOnBattery = PowerMonitor.shared.isOnBattery
        
        if isOnBattery && pauseOnBattery {
            // Pause all videos if we're on battery and the setting is enabled
            for screen in screens {
                screen.videoPlayer?.pause()
            }
        } else if !isOnBattery {
            // Only resume videos if we're on AC power
            for screen in screens {
                let screenConfig = SettingsManager.shared.getConfiguration(for: screen.id)
                // Don't resume if screen-specific pause on battery is enabled
                if !(screenConfig?.pauseOnBattery ?? false) {
                    screen.videoPlayer?.play()
                }
            }
        }
    }
    
    func handleSettingsReset() {
        // Stop all video players
        for screen in screens {
            screen.videoPlayer?.stop()
            screen.videoPlayer = nil
            screen.previewPlayer?.pause()
            screen.previewPlayer = nil
        }
        
        // Notify observers that screens need to be refreshed
        objectWillChange.send()
    }
    
    private func handlePowerStateChange() {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let isOnBattery = PowerMonitor.shared.isOnBattery
        
        for screen in screens {
            guard let player = screen.videoPlayer,
                  let configuration = SettingsManager.shared.getConfiguration(for: screen.id) else {
                continue
            }
            
            let shouldPause = (globalSettings.globalPauseOnBattery || configuration.pauseOnBattery) && isOnBattery
            
            DispatchQueue.main.async {
                if shouldPause {
                    player.pause()
                } else if !isOnBattery {
                    player.play()
                }
            }
        }
    }
    
    @objc private func screensDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshScreens()
        }
    }
    
    func setVideo(url: URL, bookmarkData: Data, for selectedScreen: Screen) {
        guard let screenIndex = screens.firstIndex(where: { $0.id == selectedScreen.id }) else { return }
        
        Task {
            do {
                // Create and verify asset
                let asset = AVURLAsset(url: url)
                let playableStatus = try await asset.load(.isPlayable)
                
                // Save configuration
                let existingConfig = SettingsManager.shared.getConfiguration(for: selectedScreen.id)
                let configuration = ScreenConfiguration(
                    screenID: selectedScreen.id,
                    videoBookmarkData: bookmarkData,
                    playbackSpeed: existingConfig?.playbackSpeed ?? 1.0,
                    pauseOnBattery: existingConfig?.pauseOnBattery ?? false
                )
                SettingsManager.shared.saveConfiguration(configuration)
                
                // Store configuration for reloading
                screenConfigurations[selectedScreen.id] = (url: url, bookmarkData: bookmarkData)
                
                await MainActor.run {
                    // Clean up existing players
                    screens[screenIndex].videoPlayer?.stop()
                    screens[screenIndex].previewPlayer?.pause()
                    screens[screenIndex].previewPlayer = nil
                    
                    // Create and configure preview player
                    let previewPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    previewPlayer.volume = 0
                    
                    // Create wallpaper player
                    let player = WallpaperVideoPlayer(
                        url: url,
                        frame: selectedScreen.frame
                    )
                    
                    // Update screen with new players
                    screens[screenIndex].videoPlayer = player
                    screens[screenIndex].previewPlayer = previewPlayer
                    
                    // Handle playback based on power state
                    let shouldPause = SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery
                        && PowerMonitor.shared.isOnBattery
                    
                    if !shouldPause {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            player.play()
                            previewPlayer.play()
                        }
                    }
                }
            } catch {
                print("Failed to setup video: \(error)")
            }
        }
    }
    
    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        if let configuration = SettingsManager.shared.getConfiguration(for: screen.id) {
            let updatedConfiguration = ScreenConfiguration(
                screenID: configuration.screenID,
                videoBookmarkData: configuration.videoBookmarkData,
                playbackSpeed: speed,
                pauseOnBattery: configuration.pauseOnBattery
            )
            SettingsManager.shared.saveConfiguration(updatedConfiguration)
            screen.videoPlayer?.setPlaybackSpeed(speed)
        }
    }
    
    deinit {
        [powerMonitorToken, powerSourceObserver].compactMap { $0 }.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        NotificationCenter.default.removeObserver(self)
        screens.forEach { cleanupScreen($0) }
    }
}
