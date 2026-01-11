import AppKit
import AVKit
import Combine

/// Video player class responsible for playing videos as desktop wallpaper
final class WallpaperVideoPlayer {
    // MARK: - Notifications

    static let didChangePlaybackStateNotification = Notification.Name("WallpaperVideoPlayerDidChangePlaybackState")

    // MARK: - Published Properties

    @Published private(set) var isPlaying: Bool = false {
        didSet {
            guard oldValue != isPlaying else { return }
            NotificationCenter.default.post(
                name: Self.didChangePlaybackStateNotification,
                object: self,
                userInfo: ["isPlaying": isPlaying]
            )
        }
    }

    @Published private(set) var loadingError: Error?
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var videoFrameRate: Double = 0

    // MARK: - Public Properties

    private(set) var player: AVPlayer?
    var videoURL: URL?

    // MARK: - Private Properties

    private weak var window: VideoWallpaperWindow?
    private weak var videoView: VideoContainerView?
    private var cleanupTasks = Set<AnyCancellable>()
    private var periodicTimeObserver: Any?
    private var playbackStateObserver: NSKeyValueObservation?
    private var loadingTask: Task<Void, Never>?
    private var frameRateLimitTask: Task<Void, Never>?
    private var accessToken = false
    private let initialFrame: CGRect
    private var fitMode: VideoFitMode = .aspectFill
    
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
        
        loadingTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let timer = PerformanceTimer(description: "Loading video asset", category: .videoPlayer)
                let asset = AVURLAsset(url: url)

                // Check for cancellation early
                try Task.checkCancellation()

                // Load essential properties asynchronously
                async let playable = asset.load(.isPlayable)
                async let duration = asset.load(.duration)

                // Check if asset is playable
                guard try await playable else {
                    self.stopAccessingResource()
                    let error = NSError(
                        domain: "WallpaperVideoPlayer",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Video is not playable"]
                    )
                    Logger.error("Video is not playable: \(url.lastPathComponent)", category: .videoPlayer)
                    self.loadingError = error
                    return
                }

                // Check for cancellation before continuing
                try Task.checkCancellation()

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

                // Check for cancellation before UI work
                try Task.checkCancellation()

                timer.checkpoint("Properties loaded")

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.configurePlaybackComponents(with: asset)
                    timer.checkpoint("Playback configured")
                }

                Logger.videoLoaded(url: url, screenID: UInt32(0)) // Will be updated later with correct screen ID
            } catch is CancellationError {
                Logger.debug("Video loading task was cancelled", category: .videoPlayer)
                self.stopAccessingResource()
            } catch {
                self.stopAccessingResource()
                Logger.error("Error loading video: \(error.localizedDescription)", category: .videoPlayer)
                self.loadingError = error
            }
        }
    }
    
    private func configurePlaybackComponents(with asset: AVURLAsset) {
        // Create an optimized player item with playback settings
        let playerItem = AVPlayerItem(asset: asset)
        
        // Set up quality of service for better performance
        playerItem.preferredForwardBufferDuration = 5.0
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        // Configure player with muted audio for wallpaper playback
        self.player = AVPlayer(playerItem: playerItem)
        self.player?.automaticallyWaitsToMinimizeStalling = true
        self.player?.volume = 0
        self.player?.isMuted = true
        self.player?.actionAtItemEnd = .none
        
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

        // Wait for player to be ready, then start playback
        setupPlayerReadyObserver()
    }

    private func setupPlayerReadyObserver() {
        guard let player = player else { return }

        var statusObserver: NSKeyValueObservation?
        statusObserver = player.observe(\.status, options: [.new, .initial]) { [weak self] observedPlayer, _ in
            guard observedPlayer.status == .readyToPlay else { return }

            Logger.debug("Player is ready to play", category: .videoPlayer)

            // Start playback with a slight delay to ensure proper initialization
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.play()
                Logger.debug("Auto-starting video playback", category: .videoPlayer)
            }

            // Remove this one-time observer
            statusObserver?.invalidate()
            statusObserver = nil
        }

        // Store the observer for cleanup
        if let observer = statusObserver {
            let cancellable = AnyCancellable {
                observer.invalidate()
            }
            cleanupTasks.insert(cancellable)
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
            .throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateWindowPositionForCurrentScreen()
            }
            .store(in: &cleanupTasks)
        
        // Also set up a periodic check to ensure window stays in position
        // This helps catch cases where the window might drift
        let timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateWindowPositionForCurrentScreen()
        }
        
        // Store the timer in cleanupTasks for proper cleanup
        cleanupTasks.insert(AnyCancellable {
            timer.invalidate()
        })
    }
    
    /// Finds the associated screen and updates the window position to match
    private func updateWindowPositionForCurrentScreen() {
        // Find the screen this player is associated with
        let associatedScreen = NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return isAssociatedWithScreen(id)
        }

        let targetScreen: NSScreen
        if let screen = associatedScreen {
            targetScreen = screen
        } else if let mainScreen = NSScreen.main {
            Logger.warning("Could not find matching screen for video player, using main screen as fallback", category: .screenManager)
            targetScreen = mainScreen
        } else {
            return
        }

        Logger.debug("Updating window frame to match screen \(targetScreen.localizedName): \(targetScreen.frame)", category: .screenManager)
        updateWindowFrame(targetScreen.frame)
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
        guard let player = player, player.timeControlStatus != .playing else { return }
        player.play()
        isPlaying = true
        Logger.debug("Video playback started", category: .videoPlayer)
    }

    func pause() {
        guard let player = player, player.timeControlStatus == .playing else { return }
        player.pause()
        isPlaying = false
        Logger.debug("Video playback paused", category: .videoPlayer)
    }

    func seek(to time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
    }

    func setPlaybackSpeed(_ speed: Double) {
        player?.rate = Float(speed)
    }

    func setVideoFitMode(_ mode: VideoFitMode) {
        guard mode != fitMode else { return }
        fitMode = mode
        videoView?.fitMode = mode
    }
    
    // MARK: - Window Management

    func updateWindowFrame(_ newFrame: CGRect) {
        guard isValidFrame(newFrame) else {
            Logger.warning("Invalid frame provided to updateWindowFrame: \(newFrame)", category: .videoPlayer)
            return
        }

        if let window = window, !areFramesEquivalent(window.frame, newFrame) {
            Logger.debug("Updating video window frame to \(newFrame)", category: .videoPlayer)
            window.updateFrame(newFrame, animate: false)
        }

        if let videoView = videoView {
            videoView.frame = NSRect(x: 0, y: 0, width: newFrame.width, height: newFrame.height)
            videoView.needsLayout = true
        }
    }

    private func isValidFrame(_ frame: CGRect) -> Bool {
        !frame.isEmpty && frame.width > 0 && frame.height > 0
    }

    private func areFramesEquivalent(_ frame1: CGRect, _ frame2: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        abs(frame1.origin.x - frame2.origin.x) < tolerance &&
        abs(frame1.origin.y - frame2.origin.y) < tolerance &&
        abs(frame1.width - frame2.width) < tolerance &&
        abs(frame1.height - frame2.height) < tolerance
    }
    
    func isAssociatedWithScreen(_ screenID: CGDirectDisplayID) -> Bool {
        guard let window = window,
              let windowScreenID = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return windowScreenID == screenID
    }

    func handleScreenParameterChange(_ screenFrame: CGRect) {
        updateWindowFrame(screenFrame)
    }
    
    // MARK: - Frame Rate Limiting
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
        
        // Cancel any previous frame rate limit task
        frameRateLimitTask?.cancel()

        frameRateLimitTask = Task { [weak self] in
            do {
                // Check for cancellation early
                try Task.checkCancellation()

                let videoTracks = try await playerItem.asset.loadTracks(withMediaType: .video)
                guard let videoTrack = videoTracks.first else {
                    Logger.warning("Cannot set frame rate limit: No video track found", category: .videoPlayer)
                    return
                }

                // Check for cancellation before loading more data
                try Task.checkCancellation()

                // Load natural video size for composition
                let naturalSize = try await videoTrack.load(.naturalSize)

                // Check for cancellation before UI work
                try Task.checkCancellation()

                await MainActor.run { [weak self] in
                    guard self != nil else { return }

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
            } catch is CancellationError {
                Logger.debug("Frame rate limit task was cancelled", category: .videoPlayer)
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

        // Cancel any pending async Tasks first
        loadingTask?.cancel()
        loadingTask = nil
        frameRateLimitTask?.cancel()
        frameRateLimitTask = nil

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
