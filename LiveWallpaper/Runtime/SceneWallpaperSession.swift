import AppKit

/// Adapter that exposes the SpriteKit-backed `SceneRenderingController` to
/// `ScreenManager` through the shared `WallpaperRuntimeSession` protocol so
/// the rest of the runtime stack does not need a scene-specific code path.
@MainActor
final class SceneWallpaperSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType = .scene

    private var window: NSWindow?
    private var controller: SceneRenderingController?
    private var currentProfile: WallpaperPerformanceProfile = .quality
    private var isVisible = true
    private var didStartLoad = false
    private(set) var isThrottled = false
    private(set) var loadError: SceneRenderingError?

    init(window: NSWindow, controller: SceneRenderingController) {
        self.window = window
        self.controller = controller
    }

    var summary: WallpaperSessionSummary {
        let activity: WallpaperSessionActivity
        if loadError != nil {
            activity = .paused
        } else if isVisible && currentProfile != .suspended {
            activity = .active
        } else {
            activity = .paused
        }
        return WallpaperSessionSummary(
            wallpaperType: .scene,
            activity: activity,
            supportsPlaybackControl: false,
            subtitle: loadError?.errorDescription
        )
    }

    var videoPlayer: WallpaperVideoPlayer? { nil }
    var wallpaperWindow: NSWindow? { window }

    /// Hand the controller out so coordinators outside the session (e.g.
    /// the exclusive-rendering coordinator) can flip throttle state without
    /// reaching through `wallpaperWindow.contentView`.
    var sceneController: SceneRenderingController? { controller }

    func updateFrame(to frame: CGRect) {
        window?.setFrame(frame, display: true)
        controller?.view.frame = CGRect(origin: .zero, size: frame.size)
    }

    func show() {
        isVisible = true
        window?.orderBack(nil)
        controller?.applyPerformanceProfile(currentProfile)
    }

    func hide() {
        isVisible = false
        window?.orderOut(nil)
        controller?.applyPerformanceProfile(.suspended)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        controller?.applyPerformanceProfile(isVisible ? profile : .suspended)
    }

    /// Exclusive-rendering coordinator entry point. Throttling is orthogonal
    /// to power profile — when console window is key we drop to 1fps even on
    /// `.quality`, then bounce back when the user goes away.
    func setThrottled(_ throttled: Bool) {
        isThrottled = throttled
        controller?.setThrottled(throttled)
    }

    func cleanup() {
        controller?.cleanup()
        controller = nil
        window?.close()
        window = nil
    }

    /// Loads the SpriteKit scene. Safe to call multiple times — only the
    /// first call performs I/O.
    func startLoadIfNeeded() {
        guard !didStartLoad, let controller else { return }
        didStartLoad = true
        Task { @MainActor [weak self] in
            do {
                try await controller.load()
                self?.loadError = nil
            } catch let error as SceneRenderingError {
                Logger.warning("Scene wallpaper load failed: \(error.errorDescription ?? "(no description)")", category: .screenManager)
                self?.loadError = error
            } catch {
                Logger.warning("Scene wallpaper load failed: \(error.localizedDescription)", category: .screenManager)
                self?.loadError = .parseFailed(error.localizedDescription)
            }
        }
    }

    // No prepareForDisplay override: the protocol-extension default
    // (50ms warm-up) gives the SpriteKit pipeline enough lead time before
    // the wallpaper window is brought to screen.
}
