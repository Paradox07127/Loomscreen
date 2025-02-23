import SwiftUI
import AVFoundation

class ScreenManager: ObservableObject {
    @Published private(set) var screens: [Screen] = []
    
    init() {
        refreshScreens()
        setupScreenObserver()
        loadSavedConfigurations()
    }
    
    func refreshScreens() {
        screens = NSScreen.screens.map { Screen(nsScreen: $0) }
    }
    
    private func setupScreenObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    @objc private func screensDidChange() {
        DispatchQueue.main.async {
            self.refreshScreens()
            self.loadSavedConfigurations()
        }
    }
    
    private func loadSavedConfigurations() {
        let configurations = SettingsManager.shared.loadConfigurations()
        
        for configuration in configurations {
            if let screen = screens.first(where: { $0.id == configuration.screenID }) {
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
                    }
                } catch {
                    print("Error loading saved configuration: \(error)")
                }
            }
        }
    }
    
    func setVideo(url: URL, bookmarkData: Data, for selectedScreen: Screen) {
        print("Setting video for screen \(selectedScreen.id)")
        print("Video URL: \(url)")
        
        guard let screenIndex = screens.firstIndex(where: { $0.id == selectedScreen.id }) else {
            print("Error: Screen not found")
            return
        }
        
        // Save the configuration
        let configuration = ScreenConfiguration(
            screenID: selectedScreen.id,
            videoBookmarkData: bookmarkData
        )
        SettingsManager.shared.saveConfiguration(configuration)
        
        DispatchQueue.main.async {
            // Stop existing players if any
            if let existingPlayer = self.screens[screenIndex].videoPlayer {
                print("Stopping existing video")
                existingPlayer.stop()
            }
            
            self.screens[screenIndex].previewPlayer?.pause()
            self.screens[screenIndex].previewPlayer = nil
            
            do {
                // Create wallpaper player
                print("Creating new video player")
                let player = WallpaperVideoPlayer(
                    url: url,
                    frame: selectedScreen.frame
                )
                
                // Create preview player
                let previewPlayer = AVPlayer(url: url)
                previewPlayer.volume = 0
                
                // Update the screen
                DispatchQueue.main.async {
                    self.screens[screenIndex].videoPlayer = player
                    self.screens[screenIndex].previewPlayer = previewPlayer
                    selectedScreen.videoPlayer = player
                    selectedScreen.previewPlayer = previewPlayer
                }
                
                print("Starting video playback")
                player.start()
                previewPlayer.play()
                
            }
        }
    }
    
    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        if let configuration = SettingsManager.shared.getConfiguration(for: screen.id) {
            let updatedConfiguration = ScreenConfiguration(
                screenID: configuration.screenID,
                videoBookmarkData: configuration.videoBookmarkData,
                playbackSpeed: speed
            )
            SettingsManager.shared.saveConfiguration(updatedConfiguration)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        screens.forEach { screen in
            screen.videoPlayer?.stop()
            screen.previewPlayer?.pause()
        }
    }
}
