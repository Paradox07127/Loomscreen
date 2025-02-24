import AppKit
import AVKit

class WallpaperVideoPlayer {
    private(set) var player: AVPlayer?
    private weak var window: VideoWallpaperWindow?
    private weak var videoView: VideoContainerView?
    private var loopObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    
    var isPlaying: Bool { player?.rate != 0 }
    
    init(url: URL, frame: CGRect) {
        // Attempt to start accessing the security-scoped resource.
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to start accessing security scoped resource for \(url)")
            return
        }
        
        Task {
            do {
                let asset = AVURLAsset(url: url)
                // Use the result of load(.isPlayable) to determine playability.
                let playable = try await asset.load(.isPlayable)
                
                guard playable else {
                    print("Asset is not playable for \(url)")
                    url.stopAccessingSecurityScopedResource()
                    return
                }
                
                // UI setup must happen on the main actor.
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.setupPlayer(with: asset, frame: frame)
                    self.setupLooping()
                    self.setupFrameObserver(initialFrame: frame)
                }
            } catch {
                print("Failed to load video asset: \(error)")
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
    
    private func setupPlayer(with asset: AVURLAsset, frame: CGRect) {
        let playerItem = AVPlayerItem(asset: asset)
        self.player = AVPlayer(playerItem: playerItem)
        self.player?.volume = 0
        
        let videoWindow = VideoWallpaperWindow(frame: frame)
        let containerView = VideoContainerView(frame: frame)
        
        videoWindow.contentView = containerView
        containerView.setPlayer(player)
        videoWindow.orderBack(nil)
        
        self.window = videoWindow
        self.videoView = containerView
        
        print("Video player setup complete with frame: \(frame)")
    }
    
    private func setupLooping() {
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.player?.seek(to: .zero)
            self.player?.play()
            print("Looping video: restarted playback.")
        }
    }
    
    private func setupFrameObserver(initialFrame: CGRect) {
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            // Find the screen intersecting the window's frame.
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) {
                if screen.frame != initialFrame {
                    window.setFrame(screen.frame, display: true)
                    self.videoView?.frame = screen.frame
                    print("Updated window and video view frame to: \(screen.frame)")
                }
            }
        }
    }
    
    func play() {
        player?.play()
        print("Playback started.")
    }
    
    func pause() {
        player?.pause()
        print("Playback paused.")
    }
    
    func togglePlayback() {
        isPlaying ? pause() : play()
    }
    
    func setPlaybackSpeed(_ speed: Double) {
        player?.rate = Float(speed)
        print("Playback speed set to \(speed)x")
    }
    
    func stop() {
        [loopObserver, frameObserver].forEach { observer in
            if let observer = observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        player?.pause()
        
        // Ensure that closing the window and UI cleanup occur on the main thread.
        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
            self?.window = nil
            self?.videoView = nil
            print("UI cleanup complete on main thread.")
        }
        
        player = nil
        print("WallpaperVideoPlayer stopped and cleaned up.")
    }

    
    deinit {
        stop()
        print("WallpaperVideoPlayer deinitialized.")
    }
}
