import AppKit
import SwiftUI
import AVKit
import Combine

class Screen: Identifiable, Hashable, ObservableObject {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let nsScreen: NSScreen

    // A method to notify observers of playback state changes
    @objc func notifyPlaybackStateChanged() {
        objectWillChange.send()
    }

    // Update videoPlayer property with observer connections
    var videoPlayer: WallpaperVideoPlayer? {
        didSet {
            // If old player exists, remove observation
            if let oldPlayer = oldValue {
                NotificationCenter.default.removeObserver(self,
                    name: WallpaperVideoPlayer.didChangePlaybackStateNotification,
                    object: oldPlayer)
            }

            // Setup observation for new player
            if let newPlayer = videoPlayer {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(notifyPlaybackStateChanged),
                    name: WallpaperVideoPlayer.didChangePlaybackStateNotification,
                    object: newPlayer
                )

                // Sync preview player with wallpaper player if both exist
                syncPreviewToWallpaper()
            }
        }
    }

    // Track if a preview player change should trigger UI updates
    private var skipPreviewPlayerNotification = false
    private var previewPlayerObserver: AnyCancellable?
    private var syncTimer: Timer?

    @Published var previewPlayer: AVPlayer? {
        willSet {
            if !skipPreviewPlayerNotification {
                // Clean up old player if there is one
                if let oldPlayer = previewPlayer {
                    oldPlayer.pause()
                }
                // Stop sync timer
                syncTimer?.invalidate()
                syncTimer = nil
            }
        }
        didSet {
            if !skipPreviewPlayerNotification {
                // Set up new player
                if let newPlayer = previewPlayer {
                    newPlayer.volume = 0
                    newPlayer.isMuted = true

                    // Disable audio session to prevent AirPods from connecting
                    if let playerItem = newPlayer.currentItem {
                        playerItem.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithm.spectral
                        // Make sure audio is disabled in all tracks
                        let audioTracks = playerItem.tracks.filter { $0.assetTrack?.mediaType == .audio }
                        for track in audioTracks {
                            track.isEnabled = false
                        }
                    }

                    // Set up observation for player status
                    previewPlayerObserver = newPlayer.publisher(for: \.status)
                        .sink { [weak self] status in
                            if status == .readyToPlay {
                                newPlayer.play()
                                // Sync with wallpaper player once ready
                                self?.syncPreviewToWallpaper()
                            }
                        }

                    // Start periodic sync with wallpaper player
                    startSyncTimer()
                }
            }
        }
    }

    /// Sync preview player position to match wallpaper player
    func syncPreviewToWallpaper() {
        guard let wallpaperPlayer = videoPlayer?.player,
              let preview = previewPlayer else { return }

        let wallpaperTime = wallpaperPlayer.currentTime()
        if wallpaperTime.isValid && !wallpaperTime.seconds.isNaN {
            preview.seek(to: wallpaperTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        // Match playback rate
        if let rate = videoPlayer?.player?.rate {
            preview.rate = rate
        }
    }

    /// Sync wallpaper player position to match preview (for seeking in UI)
    func syncWallpaperToPreview() {
        guard let wallpaperPlayer = videoPlayer?.player,
              let preview = previewPlayer else { return }

        let previewTime = preview.currentTime()
        if previewTime.isValid && !previewTime.seconds.isNaN {
            wallpaperPlayer.seek(to: previewTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func startSyncTimer() {
        syncTimer?.invalidate()
        // Sync every 5 seconds to keep players roughly aligned
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.syncPreviewToWallpaper()
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
            // Create a more descriptive fallback name with position info
            let origin = nsScreen.frame.origin
            let resolution = String(format: "%.0fx%.0f", nsScreen.frame.width, nsScreen.frame.height)
            self.name = "Display \(resolution) at (\(Int(origin.x)),\(Int(origin.y)))"
        }
        
        // Store the exact frame including origin coordinates
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
        syncTimer?.invalidate()
        syncTimer = nil
        previewPlayerObserver?.cancel()
        previewPlayer?.pause()
        previewPlayer = nil
    }
}
