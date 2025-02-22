// WallpaperVideoPlayer.swift
import AppKit
import AVKit

class WallpaperVideoPlayer {
    private var player: AVPlayer?
    private weak var window: VideoWallpaperWindow?
    private weak var videoView: VideoContainerView?
    private var itemObservation: NSKeyValueObservation?
    
    init(url: URL, frame: CGRect) {
        setupVideo(url: url, frame: frame)
    }
    
    private func setupVideo(url: URL, frame: CGRect) {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        
        player = AVPlayer(playerItem: playerItem)
        player?.actionAtItemEnd = .none
        player?.volume = 0
        
        // Observe player item status
        itemObservation = playerItem.observe(\.status) { [weak self] item, _ in
            if item.status == .readyToPlay {
                self?.start()
            }
        }
        
        let videoView = VideoContainerView(frame: frame)
        let window = VideoWallpaperWindow(frame: frame)
        window.contentView = videoView
        
        videoView.setPlayer(player)
        
        self.videoView = videoView
        self.window = window
        
        setupLooping()
        window.orderBack(nil)
    }
    
    private func setupLooping() {
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.player?.seek(to: .zero)
            self.player?.play()
        }
    }
    
    func start() {
        player?.seek(to: .zero)
        player?.play()
    }
    
    func stop() {
        itemObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
        
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
