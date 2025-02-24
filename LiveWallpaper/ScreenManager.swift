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
        // Use the new powerSource property from PowerMonitor
        if globalSettings.globalPauseOnBattery && PowerMonitor.shared.powerSource.isOnBattery {
            for screen in screens {
                screen.videoPlayer?.pause()
            }
            print("Initial pause due to battery mode.")
        }
    }
    
    // MARK: - Screen Refresh and Configuration
    
    func refreshScreens() {
        // Capture current screen states for comparison.
        let oldScreenStates = Dictionary(uniqueKeysWithValues: screens.map { screen in
            (screen.id, (frame: screen.frame, scale: screen.nsScreen.backingScaleFactor))
        })
        
        let newScreens = NSScreen.screens.map { Screen(nsScreen: $0) }
        let newScreenStates = Dictionary(uniqueKeysWithValues: newScreens.map { screen in
            (screen.id, (frame: screen.frame, scale: screen.nsScreen.backingScaleFactor))
        })
        
        // Cleanup removed screens.
        let removedScreenIDs = Set(oldScreenStates.keys).subtracting(newScreenStates.keys)
        for screenID in removedScreenIDs {
            if let screen = screens.first(where: { $0.id == screenID }) {
                cleanupScreen(screen)
            }
        }
        
        screens = newScreens
        
        // For each new or changed screen, load or reload configuration.
        for screen in screens {
            let oldState = oldScreenStates[screen.id]
            let newState = newScreenStates[screen.id]
            
            if let oldState = oldState, let newState = newState,
               (oldState.frame != newState.frame || oldState.scale != newState.scale) {
                // Screen resolution or scale changed.
                reloadVideoForScreen(screen)
            } else if oldState == nil {
                // New screen detected.
                loadConfigurationForScreen(screen)
            }
        }
        
        print("Screens refreshed. Total screens: \(screens.count)")
    }
    
    private func cleanupScreen(_ screen: Screen) {
        screen.videoPlayer?.stop()
        screen.previewPlayer?.pause()
        screen.previewPlayer = nil
        print("Cleaned up screen \(screen.id)")
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
        applyConfiguration(configuration, to: screen)
    }
    
    func reloadVideoForScreen(_ screen: Screen) {
        if let config = SettingsManager.shared.getConfiguration(for: screen.id) {
            // Preserve the playback state during a reload.
            applyConfiguration(config, to: screen, preservingState: true)
        }
    }
    
    // MARK: - Configuration Helpers
    
    private func resolveURL(from configuration: ScreenConfiguration) throws -> URL {
        var isStale = false
        return try URL(
            resolvingBookmarkData: configuration.videoBookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
    
    private func applyConfiguration(_ configuration: ScreenConfiguration, to screen: Screen, preservingState: Bool = false) {
        do {
            let url = try resolveURL(from: configuration)
            guard url.startAccessingSecurityScopedResource() else {
                print("Unable to access resource for screen \(screen.id)")
                return
            }
            
            // Optionally preserve the current playback time.
            let previousTime = preservingState ? screen.videoPlayer?.player?.currentTime() ?? .zero : .zero
            
            // Clean up any existing video player.
            cleanupScreen(screen)
            
            // Create and configure a new video player.
            let player = WallpaperVideoPlayer(url: url, frame: screen.frame)
            screen.videoPlayer = player
            player.setPlaybackSpeed(configuration.playbackSpeed)
            if preservingState {
                player.player?.seek(to: previousTime)
            }
            
            // Adjust playback based on battery settings using new power source property.
            if configuration.pauseOnBattery && PowerMonitor.shared.powerSource.isOnBattery {
                player.pause()
                print("Player paused due to battery mode.")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    player.play()
                    print("Playback started after delay on AC power.")
                }
            }
            
            url.stopAccessingSecurityScopedResource()
            print("Applied configuration for screen \(screen.id)")
        } catch {
            print("Error applying configuration for screen \(screen.id): \(error)")
        }
    }
    
    // MARK: - Observer Registration
    
    private func setupScreenObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        print("Screen observer set up.")
    }
    
    private func setupPowerObserver() {
        // Observe wake from sleep.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWakeFromSleep),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        // Observe changes in power source.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerSourceChange),
            name: PowerMonitor.powerSourceDidChangeNotification,
            object: nil
        )
        print("Power observer set up.")
    }
    
    @objc private func handleWakeFromSleep() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshScreens()
            self?.handlePowerStateChange()
        }
    }
    
    @objc private func handlePowerSourceChange() {
        print("Received power source change notification")
        handlePowerStateChange()
    }
    
    func handleGlobalPauseOnBatteryChange(_ pauseOnBattery: Bool) {
        let isOnBattery = PowerMonitor.shared.powerSource.isOnBattery
        if isOnBattery && pauseOnBattery {
            for screen in screens {
                screen.videoPlayer?.pause()
            }
            print("Paused all videos due to battery mode.")
        } else if !isOnBattery {
            for screen in screens {
                let screenConfig = SettingsManager.shared.getConfiguration(for: screen.id)
                if !(screenConfig?.pauseOnBattery ?? false) {
                    screen.videoPlayer?.play()
                }
            }
            print("Resumed videos on AC power.")
        }
    }
    
    private func handlePowerStateChange() {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let isOnBattery = PowerMonitor.shared.powerSource.isOnBattery
        
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
        print("Handled power state change: isOnBattery = \(isOnBattery)")
    }
    
    @objc private func screensDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshScreens()
        }
    }
    
    // MARK: - Video Setup via User Interaction
    
    func setVideo(url: URL, bookmarkData: Data, for selectedScreen: Screen) {
        guard let screenIndex = screens.firstIndex(where: { $0.id == selectedScreen.id }) else { return }
        
        Task {
            do {
                // Create asset and ensure it's playable.
                let asset = AVURLAsset(url: url)
                let _ = try await asset.load(.isPlayable)
                
                // Save configuration.
                let existingConfig = SettingsManager.shared.getConfiguration(for: selectedScreen.id)
                let configuration = ScreenConfiguration(
                    screenID: selectedScreen.id,
                    videoBookmarkData: bookmarkData,
                    playbackSpeed: existingConfig?.playbackSpeed ?? 1.0,
                    pauseOnBattery: existingConfig?.pauseOnBattery ?? false
                )
                SettingsManager.shared.saveConfiguration(configuration)
                self.screenConfigurations[selectedScreen.id] = (url: url, bookmarkData: bookmarkData)
                
                await MainActor.run {
                    cleanupScreen(screens[screenIndex])
                    
                    // Set up a preview player.
                    let previewPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    previewPlayer.volume = 0
                    
                    // Create wallpaper video player.
                    let player = WallpaperVideoPlayer(url: url, frame: selectedScreen.frame)
                    screens[screenIndex].videoPlayer = player
                    screens[screenIndex].previewPlayer = previewPlayer
                    
                    let shouldPause = SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery &&
                    PowerMonitor.shared.powerSource.isOnBattery
                    if !shouldPause {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            player.play()
                            previewPlayer.play()
                        }
                    }
                }
                print("Video set for screen \(selectedScreen.id)")
            } catch {
                print("Failed to setup video for screen \(selectedScreen.id): \(error)")
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
            print("Updated playback speed for screen \(screen.id) to \(speed)x")
        }
    }
    
    deinit {
        [powerMonitorToken, powerSourceObserver].compactMap { $0 }.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        NotificationCenter.default.removeObserver(self)
        screens.forEach { cleanupScreen($0) }
        print("ScreenManager deinitialized.")
    }
}
