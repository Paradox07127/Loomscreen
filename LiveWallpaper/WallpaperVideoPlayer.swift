import AppKit
import AVKit

class WallpaperVideoPlayer {
    private var player: AVPlayer?
    private weak var window: VideoWallpaperWindow?
    private weak var videoView: VideoContainerView?
    private var itemObservation: NSKeyValueObservation?
    // New property to hold the looping notification observer token
    private var loopingObserver: NSObjectProtocol?

    var isPlaying: Bool {
        return player?.rate != 0
    }

    init(url: URL, frame: CGRect) {
        setupVideo(url: url, frame: frame)
    }

    private func setupVideo(url: URL, frame: CGRect) {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        player = AVPlayer(playerItem: playerItem)
        player?.actionAtItemEnd = .none
        player?.volume = 0

        // Create views and window
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let videoView = VideoContainerView(frame: frame)
            let window = VideoWallpaperWindow(frame: frame)

            // Set up window first
            window.contentView = videoView
            window.orderBack(nil)

            // Then set up video view
            videoView.setPlayer(self.player)

            self.videoView = videoView
            self.window = window

            // Observe player item status
            self.itemObservation = playerItem.observe(\.status) { [weak self] item, _ in
                if item.status == .readyToPlay {
                    self?.start()
                }
            }

            self.setupLooping()
        }
    }

    private func setupLooping() {
        // Store the observer token so it can be removed later.
        loopingObserver = NotificationCenter.default.addObserver(
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
        // Invalidate the KVO observer
        itemObservation?.invalidate()
        // Remove the looping notification observer if set
        if let observer = loopingObserver {
            NotificationCenter.default.removeObserver(observer)
            loopingObserver = nil
        }

        player?.pause()
        player = nil

        window?.close()
        window = nil
        videoView = nil
    }

    func pause() {
        player?.pause()
    }

    func play() {
        player?.play()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func setPlaybackSpeed(_ speed: Double) {
        player?.rate = Float(speed)
    }

    deinit {
        stop()
    }
}
