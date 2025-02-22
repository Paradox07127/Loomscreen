import SwiftUI
import AVFoundation

class ScreenManager: ObservableObject {
    @Published private(set) var screens: [Screen] = []
    private var bookmarkData: [Int: Data] = [:]
    
    init() {
        refreshScreens()
        setupScreenObserver()
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
        }
    }
    
    func setVideo(url: URL, bookmarkData: Data, for selectedScreen: Screen) {
        print("Setting video for screen \(selectedScreen.id)")
        print("Video URL: \(url)")
        
        guard let screenIndex = screens.firstIndex(where: { $0.id == selectedScreen.id }) else {
            print("Error: Screen not found")
            return
        }
        
        self.bookmarkData[screenIndex] = bookmarkData
        
        DispatchQueue.main.async {
            // Stop existing players if any
            if let existingPlayer = self.screens[screenIndex].videoPlayer {
                print("Stopping existing video")
                existingPlayer.stop()
            }
            
            self.screens[screenIndex].previewPlayer?.pause()
            self.screens[screenIndex].previewPlayer = nil
            
            do {
                var isStale = false
                let resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                guard resolvedURL.startAccessingSecurityScopedResource() else {
                    print("Error: Could not access the file")
                    return
                }
                
                // Create wallpaper player
                print("Creating new video player")
                let player = WallpaperVideoPlayer(
                    url: resolvedURL,
                    frame: selectedScreen.frame
                )
                
                // Create preview player
                let previewPlayer = AVPlayer(url: resolvedURL)
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
                
            } catch {
                print("Error setting up video: \(error)")
            }
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
