import AppKit
@preconcurrency import AVKit
import Combine

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
    private(set) var shouldAutoplayWhenReady = true
    private(set) var requestedFrameRateLimit: Float = 0
    private(set) var runtimeError: WallpaperRuntimeError?
    /// Populated lazily after `loadingTask` completes by `detectFormatInfoIfNeeded`.
    /// Drives the EDR / HDR output path on the player layer + window.
    private(set) var formatInfo: VideoFormatInfo?
    /// Error sink consumed by `VideoWallpaperSession` for UI surfacing. The
    /// sink replays any pre-existing error when assigned so late observers
    /// don't miss failures raised during init.
    var onError: (@MainActor (WallpaperRuntimeError) -> Void)? {
        didSet {
            if let runtimeError {
                onError?(runtimeError)
            }
        }
    }
    var currentWindowFrame: CGRect { window?.frame ?? initialFrame }
    var currentFitMode: VideoFitMode { fitMode }

    // MARK: - Private Properties

    private var window: VideoWallpaperWindow?
    private var videoView: VideoContainerView?
    private var playerLooper: AVPlayerLooper?
    private var templatePlayerItem: AVPlayerItem?
    /// Buffered until asset loading creates the container view.
    private var pendingParticleEffect: (ParticleEffect, Double)?
    private var cleanupTasks = Set<AnyCancellable>()
    private var loadingTask: Task<Void, Never>?
    private var frameRateLimitTask: Task<Void, Never>?
    /// Mirrored onto looper items and future template clones.
    private var currentVideoComposition: AVVideoComposition?
    private var currentItemSubscription: AnyCancellable?
    private var accessToken = false
    private var lastObservedLoopCount: Int = 0
    private let initialFrame: CGRect
    private var fitMode: VideoFitMode = .aspectFill
    private var hasRequestedPlaybackStart = false
    
    // MARK: - Initialization
    init(url: URL, frame: CGRect, fitMode: VideoFitMode = .aspectFill, loadImmediately: Bool = true) {
        Logger.functionStart(category: .videoPlayer)
        self.initialFrame = frame
        self.fitMode = fitMode
        self.videoURL = url
        
        guard !frame.isEmpty else {
            let error = NSError(
                domain: "WallpaperVideoPlayer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid frame provided"]
            )
            Logger.error("Invalid frame provided: \(frame)", category: .videoPlayer)
            Logger.error("WallpaperVideoPlayer init error: \(error.localizedDescription)", category: .videoPlayer)
            reportError(.mediaNotPlayable(url, code: error.code))
            return
        }

        guard loadImmediately else {
            Logger.functionEnd(category: .videoPlayer)
            return
        }
        
        setupPlayer(with: url)
        Logger.functionEnd(category: .videoPlayer)
    }
    
    // MARK: - Video Player Setup
    private func setupPlayer(with url: URL) {
        Logger.debug("Setting up player with URL: \(url.lastPathComponent)", category: .videoPlayer)
        accessToken = url.startAccessingSecurityScopedResource()
        guard accessToken else {
            let error = NSError(
                domain: "WallpaperVideoPlayer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to access security scoped resource"]
            )
            Logger.error("Failed to access security scoped resource: \(url.lastPathComponent)", category: .videoPlayer)
            Logger.error("WallpaperVideoPlayer init error: \(error.localizedDescription)", category: .videoPlayer)
            reportError(.fileAccessDenied(url))
            return
        }

        loadingTask = Task { [weak self] in
            guard let self else { return }

            do {
                let timer = PerformanceTimer(description: "Loading video asset", category: .videoPlayer)
                let asset = AVURLAsset(url: url)

                try Task.checkCancellation()

                let isPlayable = try await asset.load(.isPlayable)

                guard isPlayable else {
                    self.stopAccessingResource()
                    Logger.error("Video is not playable: \(url.lastPathComponent)", category: .videoPlayer)
                    await MainActor.run { [weak self] in
                        self?.reportError(.mediaNotPlayable(url, code: nil))
                    }
                    return
                }

                try Task.checkCancellation()

                if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                    let frameRate = try await videoTrack.load(.nominalFrameRate)
                    await MainActor.run {
                        self.videoFrameRate = Double(frameRate)
                        Logger.debug("Video frame rate: \(self.videoFrameRate) FPS", category: .videoPlayer)
                    }
                }

                try Task.checkCancellation()

                timer.checkpoint("Properties loaded")

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.configurePlaybackComponents(with: asset)
                    timer.checkpoint("Playback configured")
                }

                do {
                    try await self.detectFormatInfoIfNeeded(for: url)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Logger.warning("Unable to detect video format: \(error.localizedDescription)", category: .videoPlayer)
                }

                Logger.debug("Video loaded: \(url.lastPathComponent)", category: .videoPlayer)
            } catch is CancellationError {
                Logger.debug("Video loading task was cancelled", category: .videoPlayer)
                self.stopAccessingResource()
            } catch {
                self.stopAccessingResource()
                Logger.error("Error loading video: \(error.localizedDescription)", category: .videoPlayer)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.reportError(self.makeRuntimeError(from: error, url: url))
                }
            }
        }
    }
    
    private func configurePlaybackComponents(with asset: AVURLAsset) {
        let playerItem = AVPlayerItem(asset: asset)

        playerItem.preferredForwardBufferDuration = 5.0
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        applyAudioPolicy(to: playerItem)

        let queuePlayer = AVQueuePlayer()
        queuePlayer.actionAtItemEnd = .none
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        queuePlayer.volume = isMuted ? 0 : 1
        queuePlayer.isMuted = isMuted
        self.player = queuePlayer
        self.templatePlayerItem = playerItem
        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        applyAudioPolicyToQueueItems()
        
        let videoWindow = VideoWallpaperWindow(frame: initialFrame)
        let containerView = VideoContainerView(frame: initialFrame)
        containerView.fitMode = fitMode
        videoWindow.contentView = containerView
        containerView.setPlayer(player)

        videoWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        videoWindow.orderBack(nil)

        self.window = videoWindow
        self.videoView = containerView

        if let formatInfo {
            applyHDRPreferenceIfNeeded(for: formatInfo)
        }

        if let pending = pendingParticleEffect {
            pendingParticleEffect = nil
            containerView.setParticleEffect(pending.0, density: pending.1)
        }

        setupPlaybackObservers()
        setupFrameObserver()
        setupFPSTracking()
        installQueueItemMaintenanceObserver()

        if queuePlayer.currentItem == nil {
            observeInitialCurrentItemForDeferredFrameRateLimit()
        } else {
            applyRequestedFrameRateLimitIfReady()
        }
        setupPlayerReadyObserver()
    }

    private func detectFormatInfoIfNeeded(for url: URL) async throws {
        guard formatInfo == nil else { return }
        let detected = try await PlayableVideoLoader.detectFormat(at: url)
        try Task.checkCancellation()
        formatInfo = detected
        applyHDRPreferenceIfNeeded(for: detected)
    }

    private func applyHDRPreferenceIfNeeded(for formatInfo: VideoFormatInfo) {
        guard formatInfo.isHDR, let videoView else { return }
        let details = formatInfo.badges.isEmpty
            ? "transfer function detected"
            : formatInfo.badges.joined(separator: " ")
        Logger.info("Video is HDR (\(details)) — enabling EDR output", category: .videoPlayer)
        videoView.applyHDRPreference(true)
        window?.setExtendedDynamicRangeEnabled(true)
    }

    private func setupPlayerReadyObserver() {
        guard let player = player else { return }

        player.publisher(for: \.status)
            .first(where: { $0 == .readyToPlay })
            .delay(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.shouldAutoplayWhenReady else { return }
                Logger.debug("Player is ready to play", category: .videoPlayer)
                self.applyAudioPolicyToQueueItems()
                self.play()
                Logger.debug("Auto-starting video playback", category: .videoPlayer)
            }
            .store(in: &cleanupTasks)
    }
    
    // MARK: - Observers
    private func setupPlaybackObservers() {
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
                if let url = self.videoURL {
                    self.reportError(self.makeRuntimeError(from: error, url: url))
                }
            }
            .store(in: &cleanupTasks)
    }
    private func setupFPSTracking() {
        let interval: TimeInterval = 0.5
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard let self, self.isPlaying else { continue }
                let estimatedFrames = EstimatedFrameTickPolicy.tickCount(
                    forFrameRate: self.videoFrameRate,
                    interval: interval
                )
                SystemMonitor.shared.tickEstimatedFrames(estimatedFrames)

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
        
        let positionTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                self?.updateWindowPositionForCurrentScreen()
            }
        }
        cleanupTasks.insert(AnyCancellable { positionTask.cancel() })
    }
    
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
        shouldAutoplayWhenReady = true
        guard let player = player else { return }
        guard !hasRequestedPlaybackStart, player.timeControlStatus != .playing else { return }
        hasRequestedPlaybackStart = true
        player.play()
        isPlaying = true
        Logger.debug("Video playback started", category: .videoPlayer)
    }

    func pause() {
        shouldAutoplayWhenReady = false
        hasRequestedPlaybackStart = false
        guard let player = player, player.timeControlStatus == .playing else { return }
        player.pause()
        isPlaying = false
        Logger.debug("Video playback paused", category: .videoPlayer)
    }

    func seek(to time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
    }

    /// Frame-accurate seek for playlist boundaries / lock-screen mirroring
    /// where the default `seek(to:)` tolerances would drift the transition by
    /// up to ~1 second on long-GOP H.264.
    func seekExact(seconds: TimeInterval) async {
        guard let player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
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
        applyAudioPolicyToQueueItems()
        player.isMuted = muted
        player.volume = muted ? 0 : 1
    }

    private func applyAudioPolicyToQueueItems() {
        guard let player else { return }
        if let templatePlayerItem {
            applyAudioPolicy(to: templatePlayerItem)
        }
        if let current = player.currentItem {
            applyAudioPolicy(to: current)
        }
        for item in player.items() where item !== player.currentItem {
            applyAudioPolicy(to: item)
        }
        player.isMuted = isMuted
        player.volume = isMuted ? 0 : 1
    }

    private func applyAudioPolicy(to playerItem: AVPlayerItem) {
        let enable = !isMuted
        for track in playerItem.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = enable
        }
    }

    private func installQueueItemMaintenanceObserver() {
        guard currentItemSubscription == nil, let queuePlayer = player else { return }
        currentItemSubscription = queuePlayer.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                guard let self else { return }
                if let item {
                    self.applyAudioPolicy(to: item)
                }
                self.applyCurrentCompositionToQueueItems()
            }
    }

    func setVideoFitMode(_ mode: VideoFitMode) {
        guard mode != fitMode else { return }
        fitMode = mode
        videoView?.fitMode = mode
    }

    func setParticleEffect(_ effect: ParticleEffect, density: Double = 1.0) {
        guard let videoView = videoView else {
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

    // MARK: - Video Composition

    func setVideoComposition(_ composition: AVVideoComposition?) {
        currentVideoComposition = composition
        applyCurrentCompositionToQueueItems()
        installCurrentItemRebindIfNeeded()
    }

    private func applyCurrentCompositionToQueueItems() {
        guard let queuePlayer = player else { return }
        let composition = currentVideoComposition
        templatePlayerItem?.videoComposition = composition
        queuePlayer.currentItem?.videoComposition = composition
        for item in queuePlayer.items() {
            item.videoComposition = composition
        }
    }

    private func installCurrentItemRebindIfNeeded() {
        installQueueItemMaintenanceObserver()
    }

    // MARK: - Frame Rate Limiting
    func setFrameRateLimit(_ framesPerSecond: Float) {
        requestedFrameRateLimit = framesPerSecond
        frameRateLimitTask?.cancel()
        frameRateLimitTask = nil

        guard let playerItem = player?.currentItem else {
            Logger.debug("Deferring frame-rate limit until player item is ready", category: .videoPlayer)
            return
        }

        if framesPerSecond <= 0 {
            setVideoComposition(nil)
            Logger.debug("Frame rate limit disabled, using native frame rate", category: .videoPlayer)
            return
        }

        let asset = playerItem.asset
        frameRateLimitTask = Task { [weak self] in
            do {
                try Task.checkCancellation()

                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = videoTracks.first else {
                    Logger.warning("Cannot set frame rate limit: No video track found", category: .videoPlayer)
                    return
                }

                try Task.checkCancellation()

                let naturalSize = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)

                try Task.checkCancellation()

                let targetFPS = framesPerSecond
                let duration = try await asset.load(.duration)

                // Apply the asset's `preferredTransform` to the layer instruction
                // so portrait video (e.g. iPhone vertical recordings) renders
                // upright. The composition `renderSize` must follow the rotated
                // bounds — using `naturalSize` directly leaves portrait video
                // letterboxed inside a landscape canvas.
                let displayed = naturalSize.applying(transform)
                let renderSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))

                var layerInstrConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
                layerInstrConfig.setTransform(transform, at: .zero)

                var instrConfig = AVVideoCompositionInstruction.Configuration()
                instrConfig.timeRange = CMTimeRange(start: .zero, duration: duration)
                instrConfig.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: layerInstrConfig)]

                var compositionConfig = AVVideoComposition.Configuration()
                compositionConfig.frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                compositionConfig.renderSize = renderSize
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

    private func observeInitialCurrentItemForDeferredFrameRateLimit() {
        guard let player else { return }
        player.publisher(for: \.currentItem)
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyRequestedFrameRateLimitIfReady()
            }
            .store(in: &cleanupTasks)
    }

    private func applyRequestedFrameRateLimitIfReady() {
        guard requestedFrameRateLimit > 0, currentVideoComposition == nil else { return }
        setFrameRateLimit(requestedFrameRateLimit)
    }

    /// Sleep / wake suspend hook. Distinct from `pause()` so the session can
    /// remember "was playing before sleep" and resume to the right state.
    func suspend() {
        pause()
    }

    func resume() {
        play()
    }

    private func reportError(_ error: WallpaperRuntimeError) {
        runtimeError = error
        onError?(error)
    }

    private func makeRuntimeError(from error: Error, url: URL) -> WallpaperRuntimeError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorNotConnectedToInternet {
            return .networkOffline
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return .fileAccessDenied(url)
        }
        return .mediaNotPlayable(url, code: nsError.code)
    }

    private func stopAccessingResource() {
        if accessToken, let url = videoURL {
            url.stopAccessingSecurityScopedResource()
            accessToken = false
        }
    }
    
    // MARK: - Cleanup
    func cleanup() {
        Logger.debug("Cleaning up video player resources", category: .videoPlayer)

        loadingTask?.cancel()
        loadingTask = nil
        frameRateLimitTask?.cancel()
        frameRateLimitTask = nil
        hasRequestedPlaybackStart = false

        pause()

        playerLooper?.disableLooping()
        playerLooper = nil
        templatePlayerItem?.videoComposition = nil
        templatePlayerItem = nil

        currentItemSubscription?.cancel()
        currentItemSubscription = nil
        currentVideoComposition = nil

        cleanupTasks.removeAll()

        videoView?.setParticleEffect(.none, density: 0)

        window?.close()

        window = nil
        videoView = nil
        player = nil
        
        stopAccessingResource()
        Logger.debug("Video player resources cleaned up", category: .videoPlayer)
    }
}
