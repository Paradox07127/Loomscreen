import AppKit
@preconcurrency import AVKit
import Combine

/// Video player class responsible for playing videos as desktop wallpaper
@MainActor
final class WallpaperVideoPlayer {
    // MARK: - Notifications

    nonisolated static let didChangePlaybackStateNotification = Notification.Name("WallpaperVideoPlayerDidChangePlaybackState")
    nonisolated static let didCompleteLoopNotification = Notification.Name.videoDidCompleteLoop

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
    /// Whether audio tracks are disabled at the AVPlayerItem level.
    private(set) var isMuted: Bool = true

    // MARK: - Private Properties

    private var window: VideoWallpaperWindow?       // strong: NSApp window list isn't always reliable for borderless wallpaper windows
    private var videoView: VideoContainerView?      // strong: tied to window's lifetime
    private var playerLooper: AVPlayerLooper?
    /// Buffered particle effect requested before `videoView` was created
    /// (e.g. user picked a video and the asset is still loading).
    private var pendingParticleEffect: (ParticleEffect, Double)?
    private var cleanupTasks = Set<AnyCancellable>()
    private var loadingTask: Task<Void, Never>?
    private var frameRateLimitTask: Task<Void, Never>?
    /// AVPlayerLooper rotates queued items, so composition must be applied to
    /// every item + re-applied on currentItem changes to avoid stale-composition
    /// compositor errors.
    private var currentVideoComposition: AVVideoComposition?
    private var currentItemSubscription: AnyCancellable?
    private var accessToken = false
    private var lastObservedLoopCount: Int = 0
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
            guard let self else { return }

            do {
                let timer = PerformanceTimer(description: "Loading video asset", category: .videoPlayer)
                let asset = AVURLAsset(url: url)

                // Check for cancellation early
                try Task.checkCancellation()

                // Load essential properties asynchronously
                let isPlayable = try await asset.load(.isPlayable)

                guard isPlayable else {
                    self.stopAccessingResource()
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
                    guard let self else { return }
                    self.configurePlaybackComponents(with: asset)
                    timer.checkpoint("Playback configured")
                }

                Logger.debug("Video loaded: \(url.lastPathComponent)", category: .videoPlayer)
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
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        // Apply current audio policy (default: tracks disabled — keeps AVF
        // from spinning up the audio engine and grabbing AirPods/output).
        applyAudioPolicy(to: playerItem)

        // Use AVQueuePlayer + AVPlayerLooper for seamless zero-cost looping
        // (avoids seek-to-zero which flushes the decode pipeline)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        queuePlayer.volume = isMuted ? 0 : 1
        queuePlayer.isMuted = isMuted
        self.player = queuePlayer
        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        
        // Create and configure window. VideoContainerView owns both the video
        // host and the particle overlay internally so frame coordinates are
        // never crossed between window-screen-space and view-local-space.
        let videoWindow = VideoWallpaperWindow(frame: initialFrame)
        let containerView = VideoContainerView(frame: initialFrame)
        containerView.fitMode = fitMode
        videoWindow.contentView = containerView
        containerView.setPlayer(player)

        // Ensure proper window level and ordering
        videoWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        videoWindow.orderBack(nil)

        self.window = videoWindow
        self.videoView = containerView

        // Drain any particle request that arrived before the view was ready.
        if let pending = pendingParticleEffect {
            pendingParticleEffect = nil
            containerView.setParticleEffect(pending.0, density: pending.1)
        }

        setupPlaybackObservers()
        setupFrameObserver()
        setupFPSTracking()

        // Wait for player to be ready, then start playback
        setupPlayerReadyObserver()
    }

    private func setupPlayerReadyObserver() {
        guard let player = player else { return }

        // Use Combine instead of KVO to avoid captured-var concurrency issues
        player.publisher(for: \.status)
            .first(where: { $0 == .readyToPlay })
            .delay(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Logger.debug("Player is ready to play", category: .videoPlayer)
                self?.play()
                Logger.debug("Auto-starting video playback", category: .videoPlayer)
            }
            .store(in: &cleanupTasks)
    }
    
    // MARK: - Observers
    private func setupPlaybackObservers() {
        // Monitor playback status via Combine (avoids KVO + DispatchQueue isolation issues)
        if let player = player {
            player.publisher(for: \.timeControlStatus)
                .map { $0 == .playing }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isCurrentlyPlaying in
                    guard let self else { return }
                    self.isPlaying = isCurrentlyPlaying
                }
                .store(in: &cleanupTasks)
        }

        // Filter benign AVPlayerLooper/compositor transition errors.
        let benignLooperCodes: Set<Int> = [-11847, -11858, -11878, -12504, -12509, -12784, -12823, -12852, -12860]
        // Don't bind to the initial currentItem: AVPlayerLooper rotates items, so
        // a single-object subscription misses later items' failure events. Use a
        // global observer + queue-membership filter instead.
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: nil)
            .sink { [weak self] notification in
                guard let self,
                      let item = notification.object as? AVPlayerItem,
                      let queue = self.player,
                      queue.items().contains(item) || queue.currentItem === item,
                      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                else { return }
                let nsError = error as NSError
                if nsError.domain == AVFoundationErrorDomain && benignLooperCodes.contains(nsError.code) {
                    return
                }
                Logger.warning("Playback item failed (code: \(nsError.code)): \(error.localizedDescription)", category: .videoPlayer)
            }
            .store(in: &cleanupTasks)

        // Looping is handled by AVPlayerLooper.
    }
    private func setupFPSTracking() {
        let interval: TimeInterval = 0.5
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isPlaying else { continue }
                let estimatedFrames = EstimatedFrameTickPolicy.tickCount(
                    forFrameRate: self.videoFrameRate,
                    interval: interval
                )
                SystemMonitor.shared.tickEstimatedFrames(estimatedFrames)

                // Detect loop completion via AVPlayerLooper.loopCount
                if let loopCount = self.playerLooper?.loopCount,
                   loopCount > self.lastObservedLoopCount {
                    self.lastObservedLoopCount = loopCount
                    NotificationCenter.default.post(
                        name: Self.didCompleteLoopNotification,
                        object: self
                    )
                }
            }
        }
        cleanupTasks.insert(AnyCancellable { task.cancel() })
    }

    private func setupFrameObserver() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateWindowPositionForCurrentScreen()
            }
            .store(in: &cleanupTasks)
        
        // Periodic check to ensure window stays in position
        // Uses structured Task instead of Timer to avoid @Sendable isolation issues
        let positionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.updateWindowPositionForCurrentScreen()
            }
        }
        cleanupTasks.insert(AnyCancellable { positionTask.cancel() })
    }
    
    /// Update window position when the associated NSScreen still exists.
    /// When no matching NSScreen is found (mid-reconfiguration), keep the existing
    /// frame instead of falling back to main screen, which would misplace the wallpaper.
    /// Recovery happens on the next screen-parameters notification + ScreenManager.hardRefresh.
    private func updateWindowPositionForCurrentScreen() {
        let associatedScreen = NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return isAssociatedWithScreen(id)
        }
        guard let targetScreen = associatedScreen else {
            Logger.debug("Skipping window-position update: associated NSScreen not found yet (display likely mid-reconfigure)", category: .screenManager)
            return
        }
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

    /// Toggle audio between disabled tracks and normal system output.
    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted

        guard let player else { return }
        // Re-apply policy on every queued + current item so looper rotations
        // inherit the new state.
        if let current = player.currentItem {
            applyAudioPolicy(to: current)
        }
        for item in player.items() where item !== player.currentItem {
            applyAudioPolicy(to: item)
        }
        player.isMuted = muted
        player.volume = muted ? 0 : 1
    }

    private func applyAudioPolicy(to playerItem: AVPlayerItem) {
        let enable = !isMuted
        for track in playerItem.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = enable
        }
    }

    func setVideoFitMode(_ mode: VideoFitMode) {
        guard mode != fitMode else { return }
        fitMode = mode
        videoView?.fitMode = mode
    }

    func setParticleEffect(_ effect: ParticleEffect, density: Double = 1.0) {
        guard let videoView = videoView else {
            // Race: configurePlaybackComponents hasn't run yet (asset still
            // loading). Buffer the request and apply when videoView is set.
            pendingParticleEffect = (effect, density)
            return
        }
        videoView.setParticleEffect(effect, density: density)
    }

    func setParticleDensity(_ density: Double) {
        videoView?.setParticleDensity(density)
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

    func setWindowVisible(_ visible: Bool) {
        guard let window else { return }
        if visible {
            window.orderBack(nil)
        } else {
            window.orderOut(nil)
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

    // MARK: - Video Composition (Centralized Owner)

    /// Sole entry point for `AVVideoComposition`. Mirrors composition onto
    /// every queued item and rebinds on looper rotation.
    func setVideoComposition(_ composition: AVVideoComposition?) {
        currentVideoComposition = composition
        applyCurrentCompositionToQueueItems()
        installCurrentItemRebindIfNeeded()
    }

    private func applyCurrentCompositionToQueueItems() {
        guard let queuePlayer = player else { return }
        let composition = currentVideoComposition
        for item in queuePlayer.items() {
            item.videoComposition = composition
        }
    }

    private func installCurrentItemRebindIfNeeded() {
        guard currentItemSubscription == nil, let queuePlayer = player else { return }
        currentItemSubscription = queuePlayer.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyCurrentCompositionToQueueItems()
            }
    }

    // MARK: - Frame Rate Limiting
    func setFrameRateLimit(_ framesPerSecond: Float) {
        guard let playerItem = player?.currentItem else {
            // Expected during reload/restart while AVPlayerItem is reattaching.
            Logger.debug("Skip frame-rate limit: no player item yet (player not ready)", category: .videoPlayer)
            return
        }

        // Cancel any previous frame rate limit task BEFORE the early-return
        // path so a stale in-flight task can't reapply a limited composition
        // after the caller asks for unlimited.
        frameRateLimitTask?.cancel()
        frameRateLimitTask = nil

        // If 0 is provided, use the original frame rate
        if framesPerSecond <= 0 {
            setVideoComposition(nil)
            Logger.debug("Frame rate limit disabled, using native frame rate", category: .videoPlayer)
            return
        }

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

                // Load natural video size for composition
                let naturalSize = try await videoTrack.load(.naturalSize)

                // Check for cancellation before UI work
                try Task.checkCancellation()

                let targetFPS = framesPerSecond
                let duration = try await asset.load(.duration)

                // Build composition entirely from Configuration API
                // (AVMutableVideoComposition* types are deprecated in macOS 26)
                let layerInstrConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)

                var instrConfig = AVVideoCompositionInstruction.Configuration()
                instrConfig.timeRange = CMTimeRange(start: .zero, duration: duration)
                instrConfig.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: layerInstrConfig)]

                var compositionConfig = AVVideoComposition.Configuration()
                compositionConfig.frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                compositionConfig.renderSize = naturalSize
                compositionConfig.instructions = [AVVideoCompositionInstruction(configuration: instrConfig)]
                compositionConfig.sourceTrackIDForFrameTiming = videoTrack.trackID

                let composition = AVVideoComposition(configuration: compositionConfig)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.setVideoComposition(composition)
                    Logger.info("Frame rate limit set to \(Int(targetFPS)) FPS", category: .videoPlayer)
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

        playerLooper?.disableLooping()
        playerLooper = nil

        currentItemSubscription?.cancel()
        currentItemSubscription = nil
        currentVideoComposition = nil

        cleanupTasks.removeAll()

        // Particle overlay is owned by VideoContainerView and torn down when
        // the window's contentView is released below.
        videoView?.setParticleEffect(.none, density: 0)

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
