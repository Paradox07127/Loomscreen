import AppKit

@MainActor
protocol WallpaperRuntimeSession: AnyObject {
    var wallpaperType: WallpaperType { get }
    var summary: WallpaperSessionSummary { get }
    var videoPlayer: WallpaperVideoPlayer? { get }
    var wallpaperWindow: NSWindow? { get }

    func show()
    func hide()
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
    func updateFrame(to frame: CGRect)
    func cleanup()

    /// Wait for the first frame so transitions do not flash empty.
    func prepareForDisplay(timeout: Duration) async -> Bool
}

extension WallpaperRuntimeSession {
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
    func cleanUp()
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

    init(player: WallpaperVideoPlayer) {
        self.player = player
    }

    var wallpaperType: WallpaperType {
        .video
    }

    var summary: WallpaperSessionSummary {
        guard let player else { return .notConfigured }
        return WallpaperSessionSummary(
            wallpaperType: .video,
            activity: player.isPlaying ? .active : .paused,
            supportsPlaybackControl: true,
            subtitle: nil
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

    func cleanup() {
        player?.cleanup()
        player = nil
    }
}

@MainActor
final class AmbientWallpaperSession: WallpaperRuntimeSession {
    private var window: NSWindow?
    private weak var performanceTarget: (any WallpaperPerformanceConfigurable)?
    private var currentProfile: WallpaperPerformanceProfile = .quality
    private var isVisible = true
    let wallpaperType: WallpaperType

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
        let activity: WallpaperSessionActivity = isVisible && currentProfile != .suspended ? .active : .paused
        return WallpaperSessionSummary(
            wallpaperType: wallpaperType,
            activity: activity,
            supportsPlaybackControl: false,
            subtitle: nil
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

    func cleanup() {
        performanceTarget?.applyPerformanceProfile(.suspended)
        (performanceTarget as? any WallpaperResourceCleanable)?.cleanUp()
        window?.close()
        window = nil
        performanceTarget = nil
    }
}
