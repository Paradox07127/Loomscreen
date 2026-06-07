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

    /// Suspend during `NSWorkspaceWillSleep` — pauses playback while remembering enough state for `resume()` to restore it.
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

/// Implemented by renderers that own a display-link-equivalent and can
/// re-target their render tempo at runtime. The plain-video path stays on the existing
/// `WallpaperVideoPlayer.setFrameRateLimit` code path because its limit
/// is interpreted as a compositing FPS via `AVVideoComposition`.
@MainActor
protocol WallpaperFrameRateConfigurable: AnyObject {
    func setFrameRateLimit(_ limit: FrameRateLimit)
}

/// Implemented by sessions whose audio is owned by something other than
/// `WallpaperVideoPlayer` (today: `WPESoundRuntime` for `.scene`). The
/// inspector's mute/volume controls route through here so they aren't
/// dead UI for non-video wallpapers.
@MainActor
protocol WallpaperAudioConfigurable: AnyObject {
    func setAudioMuted(_ muted: Bool)
    func setAudioVolume(_ volume: Double)
}

@MainActor
protocol WallpaperResourceCleanable: AnyObject {
    func cleanup()
}

@MainActor
protocol HTMLWallpaperConfigApplying: AnyObject {
    /// Applies a config to a live HTML renderer without replacing the window.
    func applyHTMLConfig(_ config: HTMLConfig) -> Bool
}

@MainActor
protocol WallpaperPlaybackControllable: WallpaperRuntimeSession {
    var isPlaying: Bool { get }
    /// The user's transient intent to play, independent of whether a
    /// performance policy is currently suppressing playback. Manual controls
    /// read this (not `isPlaying`) so a policy-suspended video still toggles
    /// from the user's point of view.
    var userIntendsToPlay: Bool { get }

    func play()
    func pause()
}

@MainActor
final class VideoWallpaperSession: WallpaperRuntimeSession, WallpaperPlaybackControllable {
    private var player: WallpaperVideoPlayer?
    /// Durable-for-the-session user intent. Set by manual play/pause; never
    /// touched by a performance-policy suspend. Combined with the current
    /// profile, this is the single authority for whether the video plays:
    /// `play = userIntendsToPlay && currentProfile == .quality`.
    private(set) var userIntendsToPlay = true
    /// Last profile applied by the policy layer. Remembered so a manual
    /// play/pause can re-derive the effective state without re-querying the
    /// policy — e.g. tapping play while on battery records intent but stays
    /// paused until the profile returns to `.quality`.
    private var currentProfile: WallpaperPerformanceProfile = .quality
    /// Mirrors `player.setWindowVisible(_:)`. When `false` the wallpaper
    /// window is `orderOut`-ed (master switch off), so the desktop shows
    /// nothing behind it — distinct from `.paused`, where the last frame
    /// stays visible.
    private var isVisible = true
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
        let activity: WallpaperSessionActivity
        if runtimeError != nil {
            activity = .error
        } else if !isVisible {
            activity = .off
        } else if player.isPlaying {
            activity = .active
        } else {
            activity = .paused
        }
        return WallpaperSessionSummary(
            wallpaperType: .video,
            activity: activity,
            supportsPlaybackControl: true,
            subtitle: runtimeError.map { PIISanitizer.scrub($0.userMessage) }
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
        userIntendsToPlay = true
        applyPerformanceProfile(currentProfile)
    }

    func pause() {
        userIntendsToPlay = false
        applyPerformanceProfile(currentProfile)
    }

    func show() {
        isVisible = true
        player?.setWindowVisible(true)
    }

    func hide() {
        isVisible = false
        player?.setWindowVisible(false)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        switch profile {
        case .quality:
            if userIntendsToPlay {
                player?.play()
            } else {
                player?.pause()
            }
        case .suspended:
            player?.pause()
        }
    }

    func suspend() {
        applyPerformanceProfile(.suspended)
    }

    func resume() {
        applyPerformanceProfile(.quality)
    }

    func retry() async {
        guard let oldPlayer = player, let url = oldPlayer.videoURL else { return }
        let frame = oldPlayer.currentWindowFrame
        let fitMode = oldPlayer.currentFitMode
        let muted = oldPlayer.isMuted
        let volume = oldPlayer.audioVolume
        let speed = Double(oldPlayer.player?.defaultRate ?? 1)
        let frameRateLimit = oldPlayer.requestedFrameRateLimit
        // Carry the user's intent + current policy profile across the rebuild
        // rather than reading the old player's autoplay flag, which a policy
        // suspend may have cleared.
        let intent = userIntendsToPlay
        let profile = currentProfile

        let packageEntryName = oldPlayer.packageEntryName
        oldPlayer.cleanup()

        let replacement = WallpaperVideoPlayer(
            url: url,
            frame: frame,
            fitMode: fitMode,
            packageEntryName: packageEntryName
        )
        attachErrorHandler(to: replacement)
        replacement.setVolume(volume)
        replacement.setMuted(muted)
        replacement.setPlaybackSpeed(speed)
        if frameRateLimit > 0 {
            replacement.setFrameRateLimit(frameRateLimit)
        }
        player = replacement
        runtimeError = replacement.runtimeError
        userIntendsToPlay = intent
        applyPerformanceProfile(profile)
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
        let activity: WallpaperSessionActivity
        if runtimeError != nil {
            activity = .error
        } else if !isVisible {
            activity = .off
        } else if currentProfile == .suspended {
            activity = .paused
        } else {
            activity = .active
        }
        return WallpaperSessionSummary(
            wallpaperType: wallpaperType,
            activity: activity,
            supportsPlaybackControl: false,
            subtitle: runtimeError.map { PIISanitizer.scrub($0.userMessage) }
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
