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
        guard url.startAccessingSecurityScopedResource() else { return }
        
        Task {
            do {
                let asset = AVURLAsset(url: url)
                try await asset.load(.isPlayable)
                
                guard asset.isPlayable else {
                    url.stopAccessingSecurityScopedResource()
                    return
                }
                
                await MainActor.run {
                    setupPlayer(with: asset, frame: frame)
                    setupLooping()
                    setupFrameObserver(frame: frame)
                }
            } catch {
                print("Failed to load video: \(error)")
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
    
    private func setupPlayer(with asset: AVURLAsset, frame: CGRect) {
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        player?.volume = 0
        
        let window = VideoWallpaperWindow(frame: frame)
        let videoView = VideoContainerView(frame: frame)
        
        window.contentView = videoView
        videoView.setPlayer(player)
        window.orderBack(nil)
        
        self.window = window
        self.videoView = videoView
    }
    
    private func setupLooping() {
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }
    }
    
    private func setupFrameObserver(frame: CGRect) {
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  let window = self.window,
                  let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) else { return }
            
            if screen.frame != frame {
                window.setFrame(screen.frame, display: true)
                videoView?.frame = screen.frame
            }
        }
    }
    
    func play() { player?.play() }
    func pause() { player?.pause() }
    func togglePlayback() { isPlaying ? pause() : play() }
    
    func setPlaybackSpeed(_ speed: Double) {
        player?.rate = Float(speed)
    }
    
    func stop() {
        [loopObserver, frameObserver].compactMap { $0 }.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        
        player?.pause()
        player = nil
        window?.close()
        window = nil
        videoView = nil
    }
    
    deinit {
        stop()
    }
}
