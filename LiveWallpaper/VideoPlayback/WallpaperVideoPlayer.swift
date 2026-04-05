import AppKit
import AVKit
import Combine

/// Video player class responsible for playing videos as desktop wallpaper
@MainActor
final class WallpaperVideoPlayer {
    // MARK: - Notifications

    nonisolated static let didChangePlaybackStateNotification = Notification.Name("WallpaperVideoPlayerDidChangePlaybackState")

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

    @Published private(set) var videoFrameRate: Double = 0

    // MARK: - Public Properties

    private(set) var player: AVQueuePlayer?
    var videoURL: URL?

    // MARK: - Private Properties

    private weak var window: VideoWallpaperWindow?
    private weak var videoView: VideoContainerView?
    private var playerLooper: AVPlayerLooper?
    private var cleanupTasks = Set<AnyCancellable>()
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
            Logger.error("WallpaperVideoPlayer init error: \(error.localizedDescription)", category: .videoPlayer)
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
            Logger.error("WallpaperVideoPlayer init error: \(error.localizedDescription)", category: .videoPlayer)
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
                let isPlayable = try await asset.load(.isPlayable)

                guard isPlayable else {
                    self.stopAccessingResource()
                    let error = NSError(
                        domain: "WallpaperVideoPlayer",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Video is not playable"]
                    )
                    Logger.error("Video is not playable: \(url.lastPathComponent)", category: .videoPlayer)
                    return
                }

                try Task.checkCancellation()

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
            }
        }
    }
    
    private func configurePlaybackComponents(with asset: AVURLAsset) {
        // Create an optimized player item with playback settings
        let playerItem = AVPlayerItem(asset: asset)
        
        // Set up quality of service for better performance
        playerItem.preferredForwardBufferDuration = 5.0
        // Battery optimization: cap decode resolution when on battery
        if PowerMonitor.shared.currentPowerSource.isOnBattery {
            playerItem.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
        }
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        // Configure player with muted audio for wallpaper playback
        // Use AVQueuePlayer + AVPlayerLooper for seamless zero-cost looping
        // (avoids seek-to-zero which flushes the decode pipeline)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        queuePlayer.volume = 0
        queuePlayer.isMuted = true
        self.player = queuePlayer
        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        
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
        
        setupPlaybackObservers()
        setupFrameObserver()
        setupFPSTracking()

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
            playbackStateObserver = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
                guard let self = self else { return }
                let isCurrentlyPlaying = player.timeControlStatus == .playing
                // KVO may fire on arbitrary threads; update @Published on main thread
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isPlaying != isCurrentlyPlaying else { return }
                    self.isPlaying = isCurrentlyPlaying
                }
            }
        }
        
        // Monitor for errors
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: player?.currentItem)
            .sink { notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    Logger.error("Playback failed: \(error.localizedDescription)", category: .videoPlayer)
                }
            }
            .store(in: &cleanupTasks)
        
        // Looping is handled by AVPlayerLooper — no manual seek needed
    }
    
    private func setupFPSTracking() {
        // Use a periodic timer to sample playback rate as an FPS proxy
        let fpsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            // AVPlayer renders at the video's native FPS (or limited by composition)
            // Report effective FPS based on videoFrameRate and frame rate limit
            let effectiveFPS = self.videoFrameRate > 0 ? self.videoFrameRate : 30.0
            // Tick once per half-second, scaled to represent the actual frame count
            for _ in 0..<Int(effectiveFPS / 2) {
                SystemMonitor.shared.tickFrame()
            }
        }
        cleanupTasks.insert(AnyCancellable { fpsTimer.invalidate() })
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
        player?.defaultRate = Float(speed)
        // Only apply rate immediately if currently playing; avoid implicit resume
        if player?.timeControlStatus == .playing {
            player?.rate = Float(speed)
        }
    }

    func setBatteryResolutionCap(_ enabled: Bool) {
        if enabled {
            player?.currentItem?.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
        } else {
            player?.currentItem?.preferredMaximumResolution = .zero
        }
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

        let asset = playerItem.asset
        frameRateLimitTask = Task { [weak self] in
            do {
                // Check for cancellation early
                try Task.checkCancellation()

                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = videoTracks.first else {
                    Logger.warning("Cannot set frame rate limit: No video track found", category: .videoPlayer)
                    return
                }

                // Check for cancellation before loading more data
                try Task.checkCancellation()

                // Load natural video size and duration for composition
                let naturalSize = try await videoTrack.load(.naturalSize)
                let assetDuration = try await asset.load(.duration)

                // Check for cancellation before UI work
                try Task.checkCancellation()

                await MainActor.run { [weak self] in
                    guard self != nil else { return }

                    // Create and apply video composition with the specified frame rate
                    let composition = AVMutableVideoComposition()
                    composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
                    composition.renderSize = naturalSize

                    // Create instruction covering the full video duration
                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(
                        start: .zero,
                        duration: assetDuration
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

        playerLooper?.disableLooping()
        playerLooper = nil

        cleanupTasks.removeAll()

        window?.close()
        
        window = nil
        videoView = nil
        player = nil
        
        // Stop accessing security-scoped resource
        stopAccessingResource()
        Logger.debug("Video player resources cleaned up", category: .videoPlayer)
    }
    
    nonisolated deinit {}
}
