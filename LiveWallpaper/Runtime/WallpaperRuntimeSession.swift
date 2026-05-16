import AppKit

@MainActor
protocol WallpaperRuntimeSession: AnyObject {
    var wallpaperType: WallpaperType { get }
    var summary: WallpaperSessionSummary { get }
    var videoPlayer: WallpaperVideoPlayer? { get }
    var wallpaperWindow: NSWindow? { get }
    /// Latest user-visible failure or `nil` while the session is healthy.
    /// Surfaced through `RuntimeErrorBanner` in screen-detail UI.
    var runtimeError: WallpaperRuntimeError? { get }

    func show()
    func hide()
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
    func updateFrame(to frame: CGRect)
    func cleanup()

    /// Suspend during `NSWorkspaceWillSleep` — pauses playback while
    /// remembering enough state for `resume()` to restore it.
    func suspend()
    /// Resume after `NSWorkspaceDidWake`.
    func resume()
    /// User-triggered retry from the error banner.
    func retry() async

    /// Wait for the first frame so transitions do not flash empty.
    func prepareForDisplay(timeout: Duration) async -> Bool
}

extension WallpaperRuntimeSession {
    var runtimeError: WallpaperRuntimeError? { nil }

    func suspend() {
        applyPerformanceProfile(.suspended)
    }

    func resume() {
        applyPerformanceProfile(.quality)
    }

    func retry() async {}

    func prepareForDisplay(timeout: Duration) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(50))
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

@MainActor
protocol WallpaperPerformanceConfigurable: AnyObject {
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
}

@MainActor
protocol WallpaperResourceCleanable: AnyObject {
    func cleanup()
}

@MainActor
protocol HTMLWallpaperConfigApplying: AnyObject {
    /// Applies a config to a live HTML renderer without replacing the window.
    /// Returns `false` when a WebKit-level choice requires a session rebuild.
    func applyHTMLConfig(_ config: HTMLConfig) -> Bool
}

@MainActor
protocol WallpaperPlaybackControllable: WallpaperRuntimeSession {
    var isPlaying: Bool { get }

    func play()
    func pause()
}

@MainActor
final class VideoWallpaperSession: WallpaperRuntimeSession, WallpaperPlaybackControllable {
    private var player: WallpaperVideoPlayer?
    private var wasPlayingBeforeSuspend: Bool?
    private(set) var runtimeError: WallpaperRuntimeError? {
        didSet {
            guard oldValue != runtimeError else { return }
            onRuntimeErrorChange?()
        }
    }
    var onRuntimeErrorChange: (@MainActor () -> Void)?

    init(player: WallpaperVideoPlayer) {
        self.player = player
        runtimeError = player.runtimeError
        attachErrorHandler(to: player)
    }

    var wallpaperType: WallpaperType {
        .video
    }

    var summary: WallpaperSessionSummary {
        guard let player else { return .notConfigured }
        let isHealthy = runtimeError == nil
        return WallpaperSessionSummary(
            wallpaperType: .video,
            activity: isHealthy && player.isPlaying ? .active : .paused,
            supportsPlaybackControl: true,
            subtitle: runtimeError?.userMessage
        )
    }

    var videoPlayer: WallpaperVideoPlayer? {
        player
    }

    var wallpaperWindow: NSWindow? {
        nil
    }

    var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    func updateFrame(to frame: CGRect) {
        player?.updateWindowFrame(frame)
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func show() {
        player?.setWindowVisible(true)
    }

    func hide() {
        player?.setWindowVisible(false)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        guard profile == .suspended else { return }
        player?.pause()
    }

    func suspend() {
        guard wasPlayingBeforeSuspend == nil else { return }
        wasPlayingBeforeSuspend = player?.isPlaying ?? false
        player?.suspend()
    }

    func resume() {
        guard let wasPlayingBeforeSuspend else { return }
        self.wasPlayingBeforeSuspend = nil
        guard wasPlayingBeforeSuspend else { return }
        player?.resume()
    }

    func retry() async {
        guard let oldPlayer = player, let url = oldPlayer.videoURL else { return }
        let frame = oldPlayer.currentWindowFrame
        let fitMode = oldPlayer.currentFitMode
        let muted = oldPlayer.isMuted
        let volume = oldPlayer.audioVolume
        let speed = Double(oldPlayer.player?.defaultRate ?? 1)
        let frameRateLimit = oldPlayer.requestedFrameRateLimit
        let shouldAutoplay = oldPlayer.isPlaying || oldPlayer.shouldAutoplayWhenReady

        oldPlayer.cleanup()

        let replacement = WallpaperVideoPlayer(url: url, frame: frame, fitMode: fitMode)
        attachErrorHandler(to: replacement)
        replacement.setVolume(volume)
        replacement.setMuted(muted)
        replacement.setPlaybackSpeed(speed)
        if frameRateLimit > 0 {
            replacement.setFrameRateLimit(frameRateLimit)
        }
        if !shouldAutoplay {
            replacement.pause()
        }
        player = replacement
        runtimeError = replacement.runtimeError
    }

    func cleanup() {
        player?.cleanup()
        player = nil
    }

    private func attachErrorHandler(to player: WallpaperVideoPlayer) {
        player.onError = { [weak self] error in
            self?.runtimeError = error
        }
    }
}

@MainActor
final class AmbientWallpaperSession: WallpaperRuntimeSession, HTMLWallpaperConfigApplying {
    private var window: NSWindow?
    private weak var performanceTarget: (any WallpaperPerformanceConfigurable)?
    private var currentProfile: WallpaperPerformanceProfile = .quality
    private var profileBeforeSuspend: WallpaperPerformanceProfile?
    private var isVisible = true
    let wallpaperType: WallpaperType
    private(set) var runtimeError: WallpaperRuntimeError? {
        didSet {
            guard oldValue != runtimeError else { return }
            onRuntimeErrorChange?()
        }
    }
    var onRuntimeErrorChange: (@MainActor () -> Void)?

    init(
        window: NSWindow,
        wallpaperType: WallpaperType,
        performanceTarget: (any WallpaperPerformanceConfigurable)?
    ) {
        precondition(wallpaperType != .video, "AmbientWallpaperSession only supports non-video wallpapers")
        self.window = window
        self.wallpaperType = wallpaperType
        self.performanceTarget = performanceTarget
    }

    var summary: WallpaperSessionSummary {
        let isHealthy = runtimeError == nil
        let activity: WallpaperSessionActivity = isHealthy && isVisible && currentProfile != .suspended ? .active : .paused
        return WallpaperSessionSummary(
            wallpaperType: wallpaperType,
            activity: activity,
            supportsPlaybackControl: false,
            subtitle: runtimeError?.userMessage
        )
    }

    var videoPlayer: WallpaperVideoPlayer? {
        nil
    }

    var wallpaperWindow: NSWindow? {
        window
    }

    func updateFrame(to frame: CGRect) {
        window?.setFrame(frame, display: true)
    }

    func show() {
        isVisible = true
        window?.orderBack(nil)
        performanceTarget?.applyPerformanceProfile(currentProfile)
    }

    func hide() {
        isVisible = false
        window?.orderOut(nil)
        performanceTarget?.applyPerformanceProfile(.suspended)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        performanceTarget?.applyPerformanceProfile(isVisible ? profile : .suspended)
    }

    func suspend() {
        guard profileBeforeSuspend == nil else { return }
        profileBeforeSuspend = currentProfile
        applyPerformanceProfile(.suspended)
    }

    func resume() {
        guard let profileBeforeSuspend else { return }
        self.profileBeforeSuspend = nil
        applyPerformanceProfile(profileBeforeSuspend)
    }

    func retry() async {
        runtimeError = nil
        (performanceTarget as? HTMLWallpaperView)?.reloadCurrentSource()
    }

    func applyHTMLConfig(_ config: HTMLConfig) -> Bool {
        guard wallpaperType == .html else { return false }
        guard let target = performanceTarget as? any HTMLWallpaperConfigApplying else { return false }
        return target.applyHTMLConfig(config)
    }

    /// Bridged from `HTMLWallpaperView.onError` so the session keeps the user-visible error.
    func recordRuntimeError(_ error: WallpaperRuntimeError) {
        runtimeError = error
    }

    func cleanup() {
        performanceTarget?.applyPerformanceProfile(.suspended)
        (performanceTarget as? any WallpaperResourceCleanable)?.cleanup()
        window?.close()
        window = nil
        performanceTarget = nil
    }
}
