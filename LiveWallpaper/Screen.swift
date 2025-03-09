import AppKit
import SwiftUI
import AVKit
import Combine

class Screen: Identifiable, Hashable, ObservableObject {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let nsScreen: NSScreen
    
    // Use private(set) for videoPlayer to control access
    var videoPlayer: WallpaperVideoPlayer?
    
    // Track if a preview player change should trigger UI updates
    private var skipPreviewPlayerNotification = false
    private var previewPlayerObserver: AnyCancellable?
    
    @Published var previewPlayer: AVPlayer? {
        willSet {
            if !skipPreviewPlayerNotification {
                // Clean up old player if there is one
                if let oldPlayer = previewPlayer {
                    oldPlayer.pause()
                }
            }
        }
        didSet {
            if !skipPreviewPlayerNotification {
                // Set up new player
                if let newPlayer = previewPlayer {
                    newPlayer.volume = 0
                    
                    // Set up observation for player status
                    previewPlayerObserver = newPlayer.publisher(for: \.status)
                        .sink { [] status in
                            if status == .readyToPlay {
                                newPlayer.play()
                            }
                        }
                }
            }
        }
    }
    
    init(nsScreen: NSScreen) {
        self.nsScreen = nsScreen
        
        // Get display ID more safely
        if let displayID = nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            self.id = displayID
        } else {
            // Fallback to a hash of the screen's properties as a temporary ID
            let screenHash = String(format: "%d-%d-%.0f-%.0f",
                                    Int(nsScreen.frame.origin.x),
                                    Int(nsScreen.frame.origin.y),
                                    nsScreen.frame.width,
                                    nsScreen.frame.height).hash
            self.id = UInt32(abs(screenHash))
        }
        
        // Get screen name
        let screenName = nsScreen.localizedName
        if !screenName.isEmpty {
            self.name = screenName
        } else {
            // Create a more descriptive fallback name
            let resolution = String(format: "%.0fx%.0f", nsScreen.frame.width, nsScreen.frame.height)
            self.name = "Display \(resolution)"
        }
        
        self.frame = nsScreen.frame
    }
    
    func setPreviewPlayer(_ player: AVPlayer?, skipNotification: Bool = false) {
        skipPreviewPlayerNotification = skipNotification
        defer { skipPreviewPlayerNotification = false }
        
        previewPlayer = player
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: Screen, rhs: Screen) -> Bool {
        lhs.id == rhs.id
    }
    
    deinit {
        previewPlayerObserver?.cancel()
        previewPlayer?.pause()
        previewPlayer = nil
    }
}
