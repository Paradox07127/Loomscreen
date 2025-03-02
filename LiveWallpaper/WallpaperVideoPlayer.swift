import AppKit
import AVKit
import Combine

/// Video player class responsible for playing videos as desktop wallpaper
final class WallpaperVideoPlayer {
    // MARK: - Properties
    private(set) var player: AVPlayer?
    private weak var window: VideoWallpaperWindow?
    private weak var videoView: VideoContainerView?
    private var cleanupTasks: Set<AnyCancellable> = []
    private var periodicTimeObserver: Any?
    private var accessToken: Bool = false // Tracks if we're accessing a security-scoped resource
    
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var loadingError: Error? = nil
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    
    private let initialFrame: CGRect
    private var fitMode: VideoFitMode = .aspectFill
    private var videoURL: URL?
    
    // MARK: - Initialization
    init(url: URL, frame: CGRect, fitMode: VideoFitMode = .aspectFill) {
        self.initialFrame = frame
        self.fitMode = fitMode
        self.videoURL = url
        
        // Validate frame
        guard !frame.isEmpty else {
            loadingError = NSError(
                domain: "WallpaperVideoPlayer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid frame provided"]
            )
            return
        }
        
        setupPlayer(with: url)
    }
    
    // MARK: - Video Player Setup
    private func setupPlayer(with url: URL) {
        // Ensure we have a valid security-scoped resource
        accessToken = url.startAccessingSecurityScopedResource()
        guard accessToken else {
            loadingError = NSError(
                domain: "WallpaperVideoPlayer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to access security scoped resource"]
            )
            return
        }
        
        Task {
            do {
                let asset = AVURLAsset(url: url)
                
                // Load essential properties asynchronously
                async let playable = asset.load(.isPlayable)
                async let duration = asset.load(.duration)
                
                // Check if asset is playable
                guard try await playable else {
                    stopAccessingResource()
                    loadingError = NSError(
                        domain: "WallpaperVideoPlayer",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Video is not playable"]
                    )
                    return
                }
                
                // Get duration
                self.duration = try await CMTimeGetSeconds(duration)
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.configurePlaybackComponents(with: asset)
                }
            } catch {
                stopAccessingResource()
                loadingError = error
            }
        }
    }
    
    private func configurePlaybackComponents(with asset: AVURLAsset) {
        // Create an optimized player item with playback settings
        let playerItem = AVPlayerItem(asset: asset)
        
        // Set up quality of service for better performance
        playerItem.preferredForwardBufferDuration = 5.0
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        // Configure player
        self.player = AVPlayer(playerItem: playerItem)
        self.player?.automaticallyWaitsToMinimizeStalling = true
        self.player?.volume = 0
        self.player?.actionAtItemEnd = .none // We'll handle looping manually
        
        // Create and configure window
        let videoWindow = VideoWallpaperWindow(frame: initialFrame)
        let containerView = VideoContainerView(frame: initialFrame)
        
        // Configure view with fit mode
        containerView.wantsLayer = true
        containerView.fitMode = fitMode
        videoWindow.contentView = containerView
        containerView.setPlayer(player)
        
        // Ensure proper window level and ordering
        videoWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        videoWindow.orderBack(nil)
        
        self.window = videoWindow
        self.videoView = containerView
        
        // Setup observers
        setupPlaybackObservers()
        setupFrameObserver()
        setupTimeObserver()
        
        // Start playback with a slight delay to ensure proper initialization
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.play()
        }
    }
    
    // MARK: - Observers
    private func setupPlaybackObservers() {
        // Monitor playback status
        player?.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                self?.isPlaying = status == .playing
            }
            .store(in: &cleanupTasks)
        
        // Monitor for errors
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: player?.currentItem)
            .sink { [weak self] notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    self?.loadingError = error
                }
            }
            .store(in: &cleanupTasks)
        
        // Setup looping
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem)
            .sink { [weak self] _ in
                self?.player?.seek(to: .zero)
                self?.player?.play()
            }
            .store(in: &cleanupTasks)
    }
    
    private func setupFrameObserver() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: true) // Throttle rapid changes
            .sink { [weak self] _ in
                guard let self = self,
                      let window = self.window,
                      let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) else {
                    return
                }
                
                let newFrame = screen.frame
                
                guard !newFrame.isEmpty else { return }
                
                window.updateFrame(newFrame, animate: true)
                self.videoView?.frame = newFrame
            }
            .store(in: &cleanupTasks)
    }
    
    private func setupTimeObserver() {
        // Add periodic time observer to track current playback position
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        
        periodicTimeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            self?.currentTime = seconds.isNaN ? 0 : seconds
        }
    }
    
    // MARK: - Playback Controls
    func play() {
        if let player = player, player.timeControlStatus != .playing {
            player.play()
        }
    }
    
    func pause() {
        if let player = player, player.timeControlStatus == .playing {
            player.pause()
        }
    }
    
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func seek(to time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
    }
    
    func setPlaybackSpeed(_ speed: Double) {
        player?.rate = Float(speed)
    }
    
    func setVideoFitMode(_ mode: VideoFitMode) {
        guard mode != fitMode else { return } // Skip if no change
        
        self.fitMode = mode
        videoView?.fitMode = mode
    }
    
    // Properly release security-scoped resource access
    private func stopAccessingResource() {
        if accessToken, let url = videoURL {
            url.stopAccessingSecurityScopedResource()
            accessToken = false
        }
    }
    
    // MARK: - Cleanup
    func cleanup() {
        pause()
        
        if let timeObserver = periodicTimeObserver, let player = player {
            player.removeTimeObserver(timeObserver)
        }
        periodicTimeObserver = nil
        
        cleanupTasks.removeAll()
        
        window?.close()
        window = nil
        videoView = nil
        player = nil
        
        // Stop accessing security-scoped resource
        stopAccessingResource()
    }
    
    deinit {
        cleanup()
    }
}
