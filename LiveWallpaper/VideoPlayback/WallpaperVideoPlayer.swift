import AppKit
import AVKit
import Combine

// Video player class responsible for playing videos as desktop wallpaper
final class WallpaperVideoPlayer {
    // MARK: - Static Notifications
    static let didChangePlaybackStateNotification = Notification.Name("WallpaperVideoPlayerDidChangePlaybackState")
 
    // MARK: - Properties
    private(set) var player: AVPlayer?
    private weak var window: VideoWallpaperWindow?
    private weak var videoView: VideoContainerView?
    private var cleanupTasks: Set<AnyCancellable> = []
    private var periodicTimeObserver: Any?
    private var accessToken: Bool = false // Tracks if we're accessing a security-scoped resource
    
    // Update the isPlaying property to post notifications when changed
        @Published private(set) var isPlaying: Bool = false {
            didSet {
                if oldValue != isPlaying {
                    NotificationCenter.default.post(
                        name: Self.didChangePlaybackStateNotification,
                        object: self,
                        userInfo: ["isPlaying": isPlaying]
                    )
                }
            }
        }

    @Published private(set) var loadingError: Error? = nil
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var videoFrameRate: Double = 0
    
    private let initialFrame: CGRect
    private var fitMode: VideoFitMode = .aspectFill
    private var videoURL: URL?
    private var playbackStateObserver: NSKeyValueObservation?
    
    // MARK: - Initialization
    init(url: URL, frame: CGRect, fitMode: VideoFitMode = .aspectFill) {
        Logger.functionStart(category: .videoPlayer)
        self.initialFrame = frame
        self.fitMode = fitMode
        self.videoURL = url
        
        // Validate frame
        guard !frame.isEmpty else {
            let error = NSError(
                domain: "WallpaperVideoPlayer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid frame provided"]
            )
            Logger.error("Invalid frame provided: \(frame)", category: .videoPlayer)
            loadingError = error
            return
        }
        
        setupPlayer(with: url)
        Logger.functionEnd(category: .videoPlayer)
    }
    
    // MARK: - Video Player Setup
    private func setupPlayer(with url: URL) {
        Logger.debug("Setting up player with URL: \(url.lastPathComponent)", category: .videoPlayer)
        // Ensure we have a valid security-scoped resource
        accessToken = url.startAccessingSecurityScopedResource()
        guard accessToken else {
            let error = NSError(
                domain: "WallpaperVideoPlayer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to access security scoped resource"]
            )
            Logger.error("Failed to access security scoped resource: \(url.lastPathComponent)", category: .videoPlayer)
            loadingError = error
            return
        }
        
        Task {
            do {
                let timer = PerformanceTimer(description: "Loading video asset", category: .videoPlayer)
                let asset = AVURLAsset(url: url)
                
                // Load essential properties asynchronously
                async let playable = asset.load(.isPlayable)
                async let duration = asset.load(.duration)
                
                // Check if asset is playable
                guard try await playable else {
                    stopAccessingResource()
                    let error = NSError(
                        domain: "WallpaperVideoPlayer",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Video is not playable"]
                    )
                    Logger.error("Video is not playable: \(url.lastPathComponent)", category: .videoPlayer)
                    loadingError = error
                    return
                }
                
                // Get duration
                self.duration = try await CMTimeGetSeconds(duration)
                Logger.debug("Video duration: \(self.duration)s", category: .videoPlayer)
                
                // Get video frame rate
                if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                    let frameRate = try await videoTrack.load(.nominalFrameRate)
                    await MainActor.run {
                        self.videoFrameRate = Double(frameRate)
                        Logger.debug("Video frame rate: \(self.videoFrameRate) FPS", category: .videoPlayer)
                    }
                }
                
                timer.checkpoint("Properties loaded")
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.configurePlaybackComponents(with: asset)
                    timer.checkpoint("Playback configured")
                }
                
                Logger.videoLoaded(url: url, screenID: UInt32(0)) // Will be updated later with correct screen ID
            } catch {
                stopAccessingResource()
                Logger.error("Error loading video: \(error.localizedDescription)", category: .videoPlayer)
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
        // Monitor playback status with more reliable KVO
        if let player = player {
            playbackStateObserver = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, change in
                guard let self = self else { return }
                let isCurrentlyPlaying = player.timeControlStatus == .playing
                if self.isPlaying != isCurrentlyPlaying {
                    self.isPlaying = isCurrentlyPlaying
                }
            }
        }
        
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
            isPlaying = true
            Logger.debug("Video playback started", category: .videoPlayer)
        }
    }
    
    func pause() {
        if let player = player, player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
            Logger.debug("Video playback paused", category: .videoPlayer)
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
    
    // Apply frame rate limit if supported

    enum FrameRateLimit: Int, CaseIterable, Identifiable, Codable {
        case fps30 = 30
        case fps60 = 60
        case unlimited = 0
        
        var id: Int { rawValue }
        
        var description: String {
            switch self {
            case .fps30: return "30 FPS"
            case .fps60: return "60 FPS"
            case .unlimited: return "Unlimited"
            }
        }
        
        var iconName: String {
            switch self {
            case .fps30: return "tortoise"
            case .fps60: return "hare"
            case .unlimited: return "infinity"
            }
        }
        
        // Calculate the effective limit taking into account both the video's native frame rate and the screen refresh rate
        func getEffectiveLimit(videoFrameRate: Double, screenRefreshRate: Double) -> Float {
            // Handle unlimited case
            if self == .unlimited {
                // When unlimited is selected, respect screen refresh rate as the maximum
                // to avoid wasting GPU resources on frames that won't be visible
                if screenRefreshRate > 0 && videoFrameRate > screenRefreshRate {
                    return Float(screenRefreshRate)
                }
                return 0 // No limit (will use video's native frame rate)
            }
            
            // Get the raw limit value
            let rawLimit = Float(self.rawValue)
            
            // If screen refresh rate is lower than the selected limit, cap at screen refresh rate
            if screenRefreshRate > 0 && screenRefreshRate < Double(rawLimit) {
                return Float(screenRefreshRate)
            }
            
            // If original frame rate is lower than the limit, no need to limit
            if videoFrameRate > 0 && videoFrameRate < Double(rawLimit) {
                return 0 // No limit needed (already below threshold)
            }
            
            // Apply the selected limit
            return rawLimit
        }
    }

    // PART 2: Let's update the WallpaperVideoPlayer's setFrameRateLimit implementation:

    // In WallpaperVideoPlayer.swift, ensure the setFrameRateLimit method is fully implemented:
    func setFrameRateLimit(_ framesPerSecond: Float) {
        guard let playerItem = player?.currentItem else {
            Logger.warning("Cannot set frame rate limit: No player item available", category: .videoPlayer)
            return
        }
        
        // If 0 is provided, use the original frame rate
        if framesPerSecond <= 0 {
            // Remove any existing composition to use native frame rate
            playerItem.videoComposition = nil
            Logger.debug("Frame rate limit disabled, using native frame rate", category: .videoPlayer)
            return
        }
        
        Task {
            do {
                let videoTracks = try await playerItem.asset.loadTracks(withMediaType: .video)
                guard let videoTrack = videoTracks.first else {
                    Logger.warning("Cannot set frame rate limit: No video track found", category: .videoPlayer)
                    return
                }
                
                // Load natural video size for composition
                let naturalSize = try await videoTrack.load(.naturalSize)
                
                await MainActor.run {
                    // Create and apply video composition with the specified frame rate
                    let composition = AVMutableVideoComposition()
                    composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
                    composition.renderSize = naturalSize
                    
                    // Create instruction
                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(
                        start: .zero,
                        duration: CMTime(value: 1, timescale: 1)
                    )
                    
                    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                    instruction.layerInstructions = [layerInstruction]
                    composition.instructions = [instruction]
                    
                    // Apply to player item
                    playerItem.videoComposition = composition
                    
                    Logger.info("Frame rate limit set to \(Int(framesPerSecond)) FPS", category: .videoPlayer)
                }
            } catch {
                Logger.error("Failed to set frame rate limit: \(error.localizedDescription)", category: .videoPlayer)
            }
        }
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
        Logger.debug("Cleaning up video player resources", category: .videoPlayer)
        pause()
        
        playbackStateObserver?.invalidate()
        playbackStateObserver = nil
        
        if let timeObserver = periodicTimeObserver, let player = player {
            player.removeTimeObserver(timeObserver)
        }
        periodicTimeObserver = nil
        
        cleanupTasks.removeAll()
        
        // Move UI operations to the main thread
        let windowToClose = window
        DispatchQueue.main.async {
            windowToClose?.close()
        }
        
        window = nil
        videoView = nil
        player = nil
        
        // Stop accessing security-scoped resource
        stopAccessingResource()
        Logger.debug("Video player resources cleaned up", category: .videoPlayer)
    }
    
    deinit {
        cleanup()
    }
}
