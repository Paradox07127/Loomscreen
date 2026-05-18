#if !LITE_BUILD
import AppKit

/// Adapter that exposes a WPE scene renderer to
/// `ScreenManager` through the shared `WallpaperRuntimeSession` protocol so
/// the rest of the runtime stack does not need a scene-specific code path.
@MainActor
final class SceneWallpaperSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType = .scene

    private var window: NSWindow?
    private var renderer: WPESceneRenderer?
    private var currentProfile: WallpaperPerformanceProfile = .quality
    private var isVisible = true
    private var didStartLoad = false
    private(set) var isThrottled = false
    private(set) var loadError: SceneRenderingError?
    /// Latest per-layer progress message reported by the renderer.
    /// Phase 2.1 surfaces this via `WPESceneDetailView` so the user sees
    /// "Decoding 7/12 textures…" instead of an opaque spinner.
    private(set) var loadProgress: String?

    init(window: NSWindow, renderer: WPESceneRenderer) {
        self.window = window
        self.renderer = renderer
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

    /// Hand the renderer out so coordinators outside the session (e.g.
    /// the exclusive-rendering coordinator) can flip throttle state without
    /// reaching through `wallpaperWindow.contentView`.
    var sceneRenderer: WPESceneRenderer? { renderer }

    func updateFrame(to frame: CGRect) {
        window?.setFrame(frame, display: true)
        renderer?.nsView.frame = CGRect(origin: .zero, size: frame.size)
    }

    func show() {
        isVisible = true
        window?.orderBack(nil)
        renderer?.applyPerformanceProfile(currentProfile)
    }

    func hide() {
        isVisible = false
        window?.orderOut(nil)
        renderer?.applyPerformanceProfile(.suspended)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        renderer?.applyPerformanceProfile(isVisible ? profile : .suspended)
    }

    /// Exclusive-rendering coordinator entry point.
    func setThrottled(_ throttled: Bool) {
        isThrottled = throttled
        renderer?.setThrottled(throttled)
    }

    func cleanup() {
        renderer?.cleanup()
        renderer = nil
        window?.close()
        window = nil
    }

    /// Loads the scene renderer.
    func startLoadIfNeeded() {
        guard !didStartLoad, let renderer else { return }
        didStartLoad = true
        installProgressHandler(on: renderer)
        Task { @MainActor [weak self] in
            do {
                try await renderer.load()
                self?.loadError = nil
                self?.loadProgress = nil
            } catch let error as SceneRenderingError {
                Logger.warning("Scene wallpaper load failed: \(error.errorDescription ?? "(no description)")", category: .screenManager)
                self?.loadError = error
            } catch {
                Logger.warning("Scene wallpaper load failed: \(error.localizedDescription)", category: .screenManager)
                if let diagnostic = renderer.loadDiagnostics {
                    self?.loadError = .resourceFailed(diagnostic)
                } else {
                    self?.loadError = .parseFailed(error.localizedDescription)
                }
            }
        }
    }

    // No prepareForDisplay override: the protocol-extension default
    // (50ms warm-up) gives the Metal renderer enough lead time to present
    // its first frame before the wallpaper window is brought to screen.

    /// Tears the controller's scene down and re-runs `load()`.
    func reload() async {
        guard let renderer else {
            loadError = .cacheRootMissing
            return
        }
        installProgressHandler(on: renderer)
        do {
            try await renderer.reload()
            loadError = nil
            loadProgress = nil
        } catch let error as SceneRenderingError {
            loadError = error
        } catch {
            if let diagnostic = renderer.loadDiagnostics {
                loadError = .resourceFailed(diagnostic)
            } else {
                loadError = .parseFailed(error.localizedDescription)
            }
        }
    }

    private func installProgressHandler(on renderer: WPESceneRenderer) {
        renderer.onProgress = { [weak self] progress in
            self?.loadProgress = progress
        }
    }
}
#endif
