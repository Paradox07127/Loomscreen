import SwiftUI
import AVFoundation

class ScreenManager: ObservableObject {
    @Published private(set) var screens: [Screen] = []
    
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
        refreshScreens()
    }
    
    func setVideo(url: URL, bookmarkData: Data, for screen: Screen) {
        guard let screenIndex = screens.firstIndex(where: { $0.id == screen.id }) else { return }
        
        // Stop existing player if any
        screens[screenIndex].videoPlayer?.stop()
        
        do {
            var isStale = false
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            guard resolvedURL.startAccessingSecurityScopedResource() else { return }
            
            let videoPlayer = WallpaperVideoPlayer(url: resolvedURL, frame: screen.frame)
            
            DispatchQueue.main.async {
                self.screens[screenIndex].videoPlayer = videoPlayer
            }
            
        } catch {
            print("Error setting video: \(error)")
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        screens.forEach { $0.videoPlayer?.stop() }
    }
}
