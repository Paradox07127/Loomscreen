import AppKit
import SwiftUI
import AVKit
import Combine

class Screen: Identifiable, Hashable, ObservableObject {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let nsScreen: NSScreen

    private var previewPlayerObserver: AnyCancellable?
    private var syncTimer: Timer?
    private var skipPreviewPlayerNotification = false

    // MARK: - Active Wallpaper Window (any type)

    /// The currently active wallpaper window (video, HTML, or shader).
    /// Managed by ScreenManager — set to nil to close.
    var activeWallpaperWindow: NSWindow? {
        willSet {
            if let old = activeWallpaperWindow, old !== newValue {
                old.close()
            }
        }
    }

    /// Current wallpaper type for this screen
    var activeWallpaperType: WallpaperType = .video

    // MARK: - Video Player

    var videoPlayer: WallpaperVideoPlayer? {
        didSet {
            guard oldValue !== videoPlayer else { return }

            // Remove observer from old player
            if let oldPlayer = oldValue {
                NotificationCenter.default.removeObserver(
                    self,
                    name: WallpaperVideoPlayer.didChangePlaybackStateNotification,
                    object: oldPlayer
                )
            }

            // Add observer to new player
            if let newPlayer = videoPlayer {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(notifyPlaybackStateChanged),
                    name: WallpaperVideoPlayer.didChangePlaybackStateNotification,
                    object: newPlayer
                )
                syncPreviewToWallpaper()
            }
        }
    }

    @objc private func notifyPlaybackStateChanged() {
        objectWillChange.send()
    }

    // MARK: - Preview Player

    @Published var previewPlayer: AVPlayer? {
        willSet {
            guard !skipPreviewPlayerNotification else { return }
            previewPlayer?.pause()
            stopSyncTimer()
        }
        didSet {
            guard !skipPreviewPlayerNotification, let newPlayer = previewPlayer else { return }
            configurePreviewPlayer(newPlayer)
        }
    }

    private func configurePreviewPlayer(_ player: AVPlayer) {
        player.volume = 0
        player.isMuted = true

        // Disable audio tracks to prevent AirPods from connecting
        if let playerItem = player.currentItem {
            playerItem.audioTimePitchAlgorithm = .spectral
            playerItem.tracks
                .filter { $0.assetTrack?.mediaType == .audio }
                .forEach { $0.isEnabled = false }
        }

        // Observe player status
        previewPlayerObserver = player.publisher(for: \.status)
            .sink { [weak self, weak player] status in
                guard status == .readyToPlay else { return }
                player?.play()
                self?.syncPreviewToWallpaper()
            }

        startSyncTimer()
    }

    // MARK: - Player Synchronization

    func syncPreviewToWallpaper() {
        guard let wallpaperPlayer = videoPlayer?.player,
              let preview = previewPlayer else { return }

        let wallpaperTime = wallpaperPlayer.currentTime()
        if wallpaperTime.isValid && !wallpaperTime.seconds.isNaN {
            preview.seek(to: wallpaperTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        preview.rate = wallpaperPlayer.rate
    }

    private func startSyncTimer() {
        stopSyncTimer()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.syncPreviewToWallpaper()
        }
    }

    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    // MARK: - Initialization

    init(nsScreen: NSScreen) {
        self.nsScreen = nsScreen
        self.frame = nsScreen.frame

        // Get display ID safely with fallback
        self.id = (nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
            ?? UInt32(abs(Self.generateFallbackID(for: nsScreen)))

        // Get screen name with fallback
        let screenName = nsScreen.localizedName
        self.name = screenName.isEmpty
            ? "Display \(Int(frame.width))x\(Int(frame.height)) at (\(Int(frame.origin.x)),\(Int(frame.origin.y)))"
            : screenName
    }

    private static func generateFallbackID(for screen: NSScreen) -> Int {
        String(format: "%d-%d-%.0f-%.0f",
               Int(screen.frame.origin.x),
               Int(screen.frame.origin.y),
               screen.frame.width,
               screen.frame.height).hash
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Screen, rhs: Screen) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Cleanup

    deinit {
        stopSyncTimer()
        previewPlayerObserver?.cancel()
        previewPlayer?.pause()
        previewPlayer = nil
        activeWallpaperWindow?.close()
        activeWallpaperWindow = nil
    }
}
