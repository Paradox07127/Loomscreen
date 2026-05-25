#if !LITE_BUILD
import AppKit

/// Adapter that exposes a WPE scene renderer to
/// `ScreenManager` through the shared `WallpaperRuntimeSession` protocol so
/// the rest of the runtime stack does not need a scene-specific code path.
@MainActor
final class SceneWallpaperSession: WallpaperRuntimeSession {
    /// Builds a replacement renderer when this session is allowed to recover
    /// from `SceneRenderingError.metalRendererUnsupported`. Returning `nil`
    /// surfaces the original error.
    typealias FallbackRendererFactory = @MainActor () -> WPESceneRenderer?

    let wallpaperType: WallpaperType = .scene

    private var window: NSWindow?
    private var renderer: WPESceneRenderer?
    private var currentProfile: WallpaperPerformanceProfile = .quality
    private var isVisible = true
    private var didStartLoad = false
    private var loadTask: Task<Void, Never>?
    private let fallbackFactory: FallbackRendererFactory?
    private var didUseFallback = false
    private(set) var isThrottled = false
    private(set) var loadError: SceneRenderingError?
    /// Latest per-layer progress message reported by the renderer.
    /// Phase 2.1 surfaces this via `WPESceneDetailView` so the user sees
    /// "Decoding 7/12 textures…" instead of an opaque spinner.
    private(set) var loadProgress: String?

    init(
        window: NSWindow,
        renderer: WPESceneRenderer,
        fallbackFactory: FallbackRendererFactory? = nil
    ) {
        self.window = window
        self.renderer = renderer
        self.fallbackFactory = fallbackFactory
    }

    var summary: WallpaperSessionSummary {
        let activity: WallpaperSessionActivity
        if loadError != nil {
            activity = .error
        } else if !isVisible {
            activity = .off
        } else if currentProfile == .suspended {
            activity = .paused
        } else {
            activity = .active
        }
        return WallpaperSessionSummary(
            wallpaperType: .scene,
            activity: activity,
            supportsPlaybackControl: false,
            subtitle: loadError?.errorDescription.map(PIISanitizer.scrub)
        )
    }

    var videoPlayer: WallpaperVideoPlayer? { nil }
    var wallpaperWindow: NSWindow? { window }

    /// Hand the renderer out so coordinators outside the session (e.g.
    /// the exclusive-rendering coordinator) can flip throttle state without
    /// reaching through `wallpaperWindow.contentView`.
    var sceneRenderer: WPESceneRenderer? { renderer }

    /// Returns the renderer when it owns its own frame-rate clock and
    /// can re-target it from the inspector's frame-rate picker.
    /// Currently the Metal renderer; the WebGL fallback uses
    /// `requestAnimationFrame` inside the WKWebView and doesn't conform.
    var frameRateController: (any WallpaperFrameRateConfigurable)? {
        renderer as? any WallpaperFrameRateConfigurable
    }

    /// Returns the renderer when it has a scene-owned audio engine
    /// (`WPESoundRuntime`) responsive to inspector mute/volume changes.
    /// Nil for renderers without sound objects.
    var audioController: (any WallpaperAudioConfigurable)? {
        renderer as? any WallpaperAudioConfigurable
    }

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
        loadTask?.cancel()
        loadTask = nil
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
        loadTask = Task { @MainActor [weak self] in
            await self?.runLoadWithFallback(initial: renderer)
            self?.loadTask = nil
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
        loadTask?.cancel()
        loadTask = nil
        installProgressHandler(on: renderer)
        do {
            try await renderer.reload()
            loadError = nil
            loadProgress = nil
        } catch is CancellationError {
            return
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

    /// Runs `load()` on `initial`. When a fallback factory is present,
    /// `SceneRenderingError.metalRendererUnsupported` swaps in that renderer
    /// and retries once. Any other failure updates `loadError` and returns.
    private func runLoadWithFallback(initial: WPESceneRenderer) async {
        var active = initial
        while true {
            do {
                try await active.load()
                guard !Task.isCancelled else { return }
                loadError = nil
                loadProgress = nil
                return
            } catch is CancellationError {
                return
            } catch let SceneRenderingError.metalRendererUnsupported(reason) {
                guard !Task.isCancelled else { return }
                if let next = await swapInFallback(reason: reason) {
                    active = next
                    continue
                }
                Logger.warning(
                    "Metal scene load failed (\(reason)); no WebGL fallback available",
                    category: .screenManager
                )
                loadError = .metalRendererUnsupported(reason: reason)
                return
            } catch let error as SceneRenderingError {
                guard !Task.isCancelled else { return }
                Logger.warning(
                    "Scene wallpaper load failed: \(error.errorDescription ?? "(no description)")",
                    category: .screenManager
                )
                loadError = error
                return
            } catch {
                guard !Task.isCancelled else { return }
                Logger.warning(
                    "Scene wallpaper load failed: \(error.localizedDescription)",
                    category: .screenManager
                )
                if let diagnostic = active.loadDiagnostics {
                    loadError = .resourceFailed(diagnostic)
                } else {
                    loadError = .parseFailed(error.localizedDescription)
                }
                return
            }
        }
    }

    private func swapInFallback(reason: String) async -> WPESceneRenderer? {
        guard !didUseFallback, let factory = fallbackFactory else { return nil }
        didUseFallback = true
        Logger.warning(
            "Metal scene load failed (\(reason)); retrying with WebGL fallback",
            category: .screenManager
        )
        WPESceneDebugArtifacts.shared.appendLog(
            "[fallback] Metal → WebGL: \(reason)",
            level: .warning
        )
        renderer?.cleanup()
        renderer = nil
        guard let next = factory() else { return nil }
        renderer = next
        if let window {
            window.contentView = next.nsView
            next.nsView.frame = window.contentView?.bounds ?? next.nsView.frame
        }
        installProgressHandler(on: next)
        next.applyPerformanceProfile(isVisible ? currentProfile : .suspended)
        if isThrottled {
            next.setThrottled(true)
        }
        return next
    }
}
#endif
