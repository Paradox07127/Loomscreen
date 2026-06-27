import AppKit
@preconcurrency import AVKit
import Combine

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
    /// Non-nil when `videoURL` is a `scene.pkg` and this entry is played in
    /// place (windowed resource loader, no extraction). Read by the runtime
    /// session when it rebuilds the player on `retry()`.
    private(set) var packageEntryName: String?
    private(set) var isMuted: Bool = true
    private(set) var audioVolume: Double = 1.0
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
    private var pendingSpanRenderConfiguration: VideoSpanRenderConfiguration?
    private var cleanupTasks = Set<AnyCancellable>()
    private var loadingTask: Task<Void, Never>?
    private var frameRateLimitTask: Task<Void, Never>?
    /// Retained for the lifetime of the player when in-memory caching is
    /// engaged. `AVAssetResourceLoader.setDelegate(_:queue:)` only keeps a
    /// weak reference, so we have to own it here.
    private var inMemoryAssetLoader: InMemoryVideoAssetLoader?
    private var currentVideoComposition: AVVideoComposition?
    private var currentItemSubscription: AnyCancellable?
    private var accessToken = false
    private let initialFrame: CGRect
    /// Screen used to cap decode resolution to the wallpaper framebuffer's
    /// physical pixels. Resolved once at player creation.
    /// TODO: refresh when a wallpaper window moves across displays.
    private var attachedScreen: NSScreen?
    private var fitMode: VideoFitMode = .aspectFill
    private var hasRequestedPlaybackStart = false
    /// Last applied colorspace preference. Re-applied in
    /// `configurePlaybackComponents` so a preference set before the asset
    /// loaded survives the late `VideoContainerView` creation path.
    private var lastColorSpacePreference: VideoColorSpace = .auto

    /// Read by composition writers (frame-rate cap, video effects) so they
    /// stand down when Rec.709 tone-mapping owns the `videoComposition` slot.
    var isForceSDRActive: Bool { lastColorSpacePreference == .forceSDR }
    
    // MARK: - Initialization
    init(
        url: URL,
        frame: CGRect,
        fitMode: VideoFitMode = .aspectFill,
        packageEntryName: String? = nil,
        loadImmediately: Bool = true
    ) {
        Logger.functionStart(category: .videoPlayer)
        self.initialFrame = frame
        self.fitMode = fitMode
        self.videoURL = url
        self.packageEntryName = packageEntryName
        
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
        if !accessToken {
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
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

            Logger.debug(
                "Using directly accessible video file without security scope: \(url.lastPathComponent)",
                category: .videoPlayer
            )
        }

        loadingTask = Task { [weak self] in
            guard let self else { return }

            do {
                let timer = PerformanceTimer(description: "Loading video asset", category: .videoPlayer)

                // In-place packaged video: build a custom-scheme asset backed by
                // a resource loader windowed into the scene.pkg. The same asset
                // is used for probing (isPlayable/tracks/duration) and playback;
                // there is no plain file URL to open.
                let asset: AVURLAsset
                let packagedLoader: InMemoryVideoAssetLoader?
                if let entryName = self.packageEntryName {
                    let result = try await Task.detached(priority: .utility) {
                        try InMemoryVideoAssetLoader.loadPackageEntry(packageURL: url, entryName: entryName)
                    }.value
                    try Task.checkCancellation()
                    let memAsset = AVURLAsset(url: result.customURL, options: Self.inMemoryAssetOptions)
                    memAsset.resourceLoader.setDelegate(result.loader, queue: Self.resourceLoaderQueue)
                    asset = memAsset
                    packagedLoader = result.loader
                } else {
                    asset = AVURLAsset(url: url)
                    packagedLoader = nil
                }

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

                let cmDuration = try? await asset.load(.duration)
                let durationSeconds = Self.usableDuration(from: cmDuration)

                let activeAsset: AVURLAsset
                let loader: InMemoryVideoAssetLoader?
                let bufferDuration: TimeInterval

                if let packagedLoader {
                    // Packaged video always serves windowed from the mapped
                    // package (mmap pages in lazily, covering small + large
                    // clips); skip the file-size in-memory/stream decision.
                    activeAsset = asset
                    loader = packagedLoader
                    bufferDuration = Self.inMemoryBufferDuration
                } else {
                    let fileSize = Self.fileSize(of: url)
                    let memoryCached = Self.shouldUseInMemoryCache(fileSize: fileSize)
                    // Differentiated buffer hint: in-memory path doesn't need
                    // to pre-fetch ahead because the bytes are already in RAM,
                    // so we skip the "buffer the entire short clip" behaviour
                    // that exists to absorb loop-wrap disk reads on streaming.
                    // This cuts AVFoundation's per-player buffer state from
                    // ~duration×bitrate to a flat ~2s, which is the dominant
                    // savings on multi-screen same-video setups.
                    bufferDuration = memoryCached
                        ? Self.inMemoryBufferDuration
                        : Self.bufferDuration(forDuration: durationSeconds)

                    if memoryCached {
                        do {
                            // Hop off MainActor for the synchronous mmap +
                            // file-attribute walk inside `load(from:)`. On a
                            // 4K@60 clip this can touch several hundred MB
                            // of virtual memory mapping — even when
                            // `mappedIfSafe` succeeds the syscall cost is
                            // non-trivial and shouldn't sit on main.
                            let result = try await Task.detached(priority: .utility) {
                                try InMemoryVideoAssetLoader.load(from: url)
                            }.value
                            try Task.checkCancellation()
                            let memAsset = AVURLAsset(url: result.customURL, options: Self.inMemoryAssetOptions)
                            memAsset.resourceLoader.setDelegate(result.loader, queue: Self.resourceLoaderQueue)
                            activeAsset = memAsset
                            loader = result.loader
                            Logger.info(
                                "Loaded \(fileSize / (1024 * 1024)) MB video into RAM — 0 physical reads expected after warmup",
                                category: .videoPlayer
                            )
                        } catch {
                            Logger.info(
                                "In-memory load failed (\(error.localizedDescription)) — falling back to streaming",
                                category: .videoPlayer
                            )
                            activeAsset = asset
                            loader = nil
                        }
                    } else {
                        activeAsset = asset
                        loader = nil
                        let budgetMB = SettingsManager.shared.loadGlobalSettings()
                            .videoCacheMaxBytesPerScreen / (1024 * 1024)
                        Logger.debug(
                            "Streaming from disk: \(fileSize / (1024 * 1024)) MB exceeds in-memory budget (\(budgetMB) MB). Raise the slider in General Settings to keep this clip in RAM.",
                            category: .videoPlayer
                        )
                    }
                }

                timer.checkpoint("Properties loaded")

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.inMemoryAssetLoader = loader
                    self.configurePlaybackComponents(with: activeAsset, bufferDuration: bufferDuration)
                    timer.checkpoint("Playback configured")
                }

                do {
                    // Probe HDR/codec from the active asset: for packaged /
                    // in-memory videos there is no plain file URL, and the
                    // windowed custom-scheme asset answers track queries fine.
                    try await self.detectFormatInfoIfNeeded(asset: activeAsset)
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
    
    /// Upper bound on `preferredForwardBufferDuration`. Above this we fall
    /// back to the default 5s buffer rather than asking AVFoundation to keep
    /// the whole file in RAM — a 5-minute 4K clip would otherwise pin ~2 GB
    /// of buffer per active screen.
    private static let fullBufferCapSeconds: TimeInterval = 60

    /// Forward-buffer hint used when serving from the in-memory loader.
    /// The underlying bytes are already in RAM (mmap'd), so AVFoundation
    /// doesn't need the streaming-path "buffer the whole clip" rule —
    /// but we pick 5s (not lower) to keep clear decoder headroom on
    /// high-bitrate 4K@60 sources where the wrap-around could otherwise
    /// briefly chase the decode pipeline.
    private static let inMemoryBufferDuration: TimeInterval = 5

    /// Serial queue dedicated to in-memory resource-loader callbacks.
    /// Keeps byte-range responses and `Data(slice)` copies off the main
    /// queue so a large file (now possible after lifting the duration
    /// gate) can't stall UI when AVFoundation asks for a chunky range.
    private static let resourceLoaderQueue = DispatchQueue(
        label: "app.livewallpaper.video.in-memory-loader",
        qos: .userInitiated
    )

    /// Asset options for custom-scheme (`lwmem://`) assets — both the in-memory
    /// file loader and the in-place packaged loader. Forbids AVFoundation from
    /// resolving any external reference or touching the network.
    private static let inMemoryAssetOptions: [String: Any] = [
        AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        AVURLAssetAllowsCellularAccessKey: false,
        AVURLAssetAllowsExpensiveNetworkAccessKey: false,
        AVURLAssetAllowsConstrainedNetworkAccessKey: false
    ]

    /// Validates an in-place packaged video by building the windowed
    /// custom-scheme asset and probing `isPlayable` — there is no plain file
    /// URL to hand the URL-based validator. The loader is held alive across the
    /// async probe so AVFoundation's weak delegate ref stays valid.
    static func validatePackagedVideo(packageURL: URL, entryName: String) async throws {
        // Mapping the package requires the security scope active; unlike the
        // player path (which holds it via `accessToken`), this static helper is
        // reached from the bookmark-apply flow with no scope held.
        let didStart = packageURL.startAccessingSecurityScopedResource()
        defer { if didStart { packageURL.stopAccessingSecurityScopedResource() } }

        let result = try InMemoryVideoAssetLoader.loadPackageEntry(packageURL: packageURL, entryName: entryName)
        let asset = AVURLAsset(url: result.customURL, options: inMemoryAssetOptions)
        asset.resourceLoader.setDelegate(result.loader, queue: resourceLoaderQueue)
        try await PlayableVideoLoader.validatePlayableVideo(asset: asset)
        withExtendedLifetime(result.loader) {}
    }


    private static func fileSize(of url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.intValue
    }

    /// File size is the only real constraint: once a file fits the budget,
    /// mmap-backed playback works regardless of duration. Users who don't
    /// want a long low-bitrate clip in RAM should lower the budget slider.
    private static func shouldUseInMemoryCache(fileSize: Int) -> Bool {
        guard fileSize > 0 else { return false }
        let budget = SettingsManager.shared.loadGlobalSettings().videoCacheMaxBytesPerScreen
        guard budget > 0 else { return false }
        return fileSize <= budget
    }

    /// Extra headroom appended to the video duration when full-buffer mode
    /// is engaged. Keeps the loop wrap-around from triggering a fresh
    /// disk fetch when the player is reading slightly past `duration`
    /// (`AVPlayerLooper` cross-fades a few frames between iterations).
    private static let bufferSafetyMargin: TimeInterval = 2

    private static func usableDuration(from cmTime: CMTime?) -> TimeInterval {
        guard let cmTime, cmTime.isValid, !cmTime.isIndefinite else { return 0 }
        let seconds = cmTime.seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    private static func bufferDuration(forDuration durationSeconds: TimeInterval) -> TimeInterval {
        guard durationSeconds > 0 else { return 5 }
        if durationSeconds <= fullBufferCapSeconds {
            return durationSeconds + bufferSafetyMargin
        }
        return 5
    }

    private func configurePlaybackComponents(with asset: AVURLAsset, bufferDuration: TimeInterval) {
        attachedScreen = Self.screen(matching: initialFrame)
        let playerItem = AVPlayerItem(asset: asset)

        playerItem.preferredForwardBufferDuration = bufferDuration
        // Wallpaper sources are local file:// or lwmem:// assets. Avoid seek
        // waits intended for composition-heavy editors, use the cheaper audio
        // pitch path for ambient playback, and let local loops advance eagerly.
        if #available(macOS 10.15, *) {
            playerItem.seekingWaitsForVideoCompositionRendering = false
        }
        playerItem.audioTimePitchAlgorithm = .timeDomain
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        Logger.debug("Forward buffer hint: \(String(format: "%.1f", bufferDuration))s", category: .videoPlayer)

        Self.applyResolutionCap(to: playerItem, screen: attachedScreen)
        applyAudioPolicy(to: playerItem)

        let queuePlayer = AVQueuePlayer()
        queuePlayer.actionAtItemEnd = .none
        // All wallpaper video sources are local (file:// or lwmem://), so the
        // remote-stream buffering heuristics only add loop-transition latency.
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        queuePlayer.volume = isMuted ? 0 : Float(audioVolume)
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
        containerView.setSpanRenderConfiguration(pendingSpanRenderConfiguration)

        videoWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        videoWindow.orderBack(nil)

        self.window = videoWindow
        self.videoView = containerView

        // Late-binding: a preference set before the container existed only
        // applied to `lastColorSpacePreference`. Now that the container is
        // live, push it onto the player layer. `.forceSDR` additionally
        // needs the Rec.709 composition, which couldn't install earlier
        // because `templatePlayerItem` didn't exist yet.
        if lastColorSpacePreference != .auto {
            containerView.applyColorSpacePreference(lastColorSpacePreference)
            if lastColorSpacePreference == .forceSDR {
                installSDRComposition()
            }
        }

        if let formatInfo {
            applyHDRPreferenceIfNeeded(for: formatInfo)
        }

        if let pending = pendingParticleEffect {
            pendingParticleEffect = nil
            containerView.setParticleEffect(pending.0, density: pending.1)
        }

        setupPlaybackObservers()
        setupFrameObserver()
        installQueueItemMaintenanceObserver()

        if queuePlayer.currentItem == nil {
            observeInitialCurrentItemForDeferredFrameRateLimit()
        } else {
            applyRequestedFrameRateLimitIfReady()
        }
        setupPlayerReadyObserver()
    }

    private func detectFormatInfoIfNeeded(asset: AVURLAsset) async throws {
        guard formatInfo == nil else { return }
        let detected = try await PlayableVideoLoader.detectFormat(asset: asset)
        try Task.checkCancellation()
        formatInfo = detected
        applyHDRPreferenceIfNeeded(for: detected)
    }

    private func applyHDRPreferenceIfNeeded(for formatInfo: VideoFormatInfo) {
        guard formatInfo.isHDR, let videoView else { return }
        let details = formatInfo.badges.isEmpty
            ? "transfer function detected"
            : formatInfo.badges.map(\.displayLabel).joined(separator: " ")
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
        guard let player else { return }
        let wasActive = isPlaying || player.timeControlStatus != .paused
        player.pause()
        if isPlaying {
            isPlaying = false
        }
        if wasActive {
            Logger.debug("Video playback paused", category: .videoPlayer)
        }
    }

    func setPlaybackSpeed(_ speed: Double) {
        player?.defaultRate = Float(speed)
        if player?.timeControlStatus == .playing {
            player?.rate = Float(speed)
        }
    }

    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted

        applyAudioPolicyToQueueItems()
    }

    func setVolume(_ volume: Double) {
        let clampedVolume = Self.clampedVolume(volume)
        guard abs(audioVolume - clampedVolume) > 0.001 else { return }
        audioVolume = clampedVolume
        updatePlayerAudioOutput()
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
        updatePlayerAudioOutput()
    }

    private func updatePlayerAudioOutput() {
        guard let player else { return }
        player.isMuted = isMuted
        player.volume = isMuted ? 0 : Float(audioVolume)
    }

    private func applyAudioPolicy(to playerItem: AVPlayerItem) {
        let enable = !isMuted
        for track in playerItem.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = enable
        }
    }

    /// AVFoundation never lets us pick the decoder backend (hardware vs.
    /// software) directly — that decision lives in VideoToolbox. What we
    /// CAN do is stop the decoder from chewing through 8K data when the
    /// framebuffer is only 4K. Capping at the framebuffer's physical
    /// pixels is the information ceiling: anything above it would be
    /// downsampled before display, so the cap saves GPU + memory without
    /// any visible loss.
    static func applyResolutionCap(to playerItem: AVPlayerItem, screen: NSScreen?) {
        guard let screen else {
            // No screen context yet — leave the defaults so AVFoundation
            // picks something sane on the first frame. The cap will be
            // re-applied once `attachedScreen` resolves.
            return
        }
        playerItem.preferredMaximumResolution = CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )
        playerItem.preferredPeakBitRate = 0
    }

    private static func screen(matching frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { Self.areFramesEquivalent($0.frame, frame) }
    }

    private static func clampedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0), 1)
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

    /// `.forceSDR` installs a Rec.709 `AVVideoComposition` so HDR sources
    /// tone-map to standard dynamic range — composition-based, so it is
    /// mutually exclusive with `setFrameRateLimit` (re-applying either
    /// replaces the active composition).
    func setVideoColorSpace(_ preference: VideoColorSpace) {
        let previousPreference = lastColorSpacePreference
        lastColorSpacePreference = preference
        videoView?.applyColorSpacePreference(preference)

        if preference == .forceSDR {
            // Cancel any in-flight frame-rate composition build so its
            // late completion can't race past the Rec.709 install.
            frameRateLimitTask?.cancel()
            frameRateLimitTask = nil
            installSDRComposition()
        } else if previousPreference == .forceSDR {
            // Drop the Rec.709 composition when the user picks a non-forceSDR
            // option so the natural HDR / wide-gamut path resumes. If a
            // frame-rate limit was previously set, it now needs to be
            // re-applied because `setFrameRateLimit` builds its own
            // composition only when invoked explicitly.
            setVideoComposition(nil)
            if requestedFrameRateLimit > 0 {
                setFrameRateLimit(requestedFrameRateLimit)
            }
        }
    }

    private func installSDRComposition() {
        guard let templateItem = templatePlayerItem else {
            // No asset yet — the composition gets installed on the late path
            // by `configurePlaybackComponents`, which calls back into us via
            // `lastColorSpacePreference`. Defer.
            return
        }
        let asset = templateItem.asset
        let composition = AVMutableVideoComposition(
            asset: asset,
            applyingCIFiltersWithHandler: { request in
                request.finish(with: request.sourceImage, context: nil)
            }
        )
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        setVideoComposition(composition)
    }

    func setSpanRenderConfiguration(_ configuration: VideoSpanRenderConfiguration?) {
        pendingSpanRenderConfiguration = configuration
        videoView?.setSpanRenderConfiguration(configuration)
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

        // TODO P2: refresh attachedScreen and reapply decoder caps on cross-display moves.
        if let window = window, !Self.areFramesEquivalent(window.frame, newFrame) {
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

    private static func areFramesEquivalent(_ frame1: CGRect, _ frame2: CGRect, tolerance: CGFloat = 1.0) -> Bool {
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

        // Force SDR owns the active composition (Rec.709 tone-mapping). The
        // frame-rate cap also writes through `videoComposition`, so trying
        // to install both produces whichever was applied last. The UI text
        // for `.forceSDR` documents this exclusion — honour it here so the
        // SDR composition isn't silently overwritten by a profile-driven
        // refresh.
        guard lastColorSpacePreference != .forceSDR else {
            Logger.debug("Skipping frame-rate composition while Force SDR is active", category: .videoPlayer)
            return
        }

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

                let displayed = naturalSize.applying(transform)
                let renderSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))

                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                let composition: AVVideoComposition

                if #available(macOS 26.0, *) {
                    var layerInstrConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
                    layerInstrConfig.setTransform(transform, at: .zero)

                    var instrConfig = AVVideoCompositionInstruction.Configuration()
                    instrConfig.timeRange = CMTimeRange(start: .zero, duration: duration)
                    instrConfig.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: layerInstrConfig)]

                    var compositionConfig = AVVideoComposition.Configuration()
                    compositionConfig.frameDuration = frameDuration
                    compositionConfig.renderSize = renderSize
                    compositionConfig.instructions = [AVVideoCompositionInstruction(configuration: instrConfig)]
                    compositionConfig.sourceTrackIDForFrameTiming = videoTrack.trackID

                    composition = AVVideoComposition(configuration: compositionConfig)
                } else {
                    let layerInstr = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                    layerInstr.setTransform(transform, at: .zero)

                    let instr = AVMutableVideoCompositionInstruction()
                    instr.timeRange = CMTimeRange(start: .zero, duration: duration)
                    instr.layerInstructions = [layerInstr]

                    let mutableComposition = AVMutableVideoComposition()
                    mutableComposition.frameDuration = frameDuration
                    mutableComposition.renderSize = renderSize
                    mutableComposition.instructions = [instr]
                    mutableComposition.sourceTrackIDForFrameTiming = videoTrack.trackID

                    composition = mutableComposition
                }

                await MainActor.run { [weak self] in
                    // Bail if Force SDR took ownership of the composition
                    // slot while we were building the frame-rate variant.
                    guard let self, !self.isForceSDRActive else { return }
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

    /// Sleep / wake suspend hook.
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

        if inMemoryAssetLoader != nil {
            Logger.info("Releasing in-memory video cache for \(videoURL?.lastPathComponent ?? "<unknown>")", category: .videoPlayer)
        }
        inMemoryAssetLoader = nil

        cleanupTasks.removeAll()

        videoView?.setParticleEffect(.none, density: 0)

        window?.close()

        window = nil
        videoView = nil
        player = nil
        
        stopAccessingResource()
        Logger.debug("Video player resources cleaned up", category: .videoPlayer)
    }

    deinit {
        let url = videoURL
        let hadAccess = accessToken
        if hadAccess, let url {
            Task { @MainActor in
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}
