#if !LITE_BUILD
import AppKit
import LiveWallpaperVideoWeb

/// Adapter that exposes a WPE scene renderer to
/// `ScreenManager` through the shared `WallpaperRuntimeSession` protocol so
/// the rest of the runtime stack does not need a scene-specific code path.
@MainActor
final class SceneWallpaperSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType = .scene

    private var window: NSWindow?
    private var renderer: WPEMetalSceneRenderer?
    private var currentProfile: WallpaperPerformanceProfile = .quality
    private var isVisible = true
    private var didStartLoad = false
    private var loadTask: Task<Void, Never>?
    private(set) var loadError: SceneRenderingError?
    /// Latest per-layer progress message reported by the renderer.
    /// Phase 2.1 surfaces this via `WPESceneDetailView` so the user sees
    /// "Decoding 7/12 textures…" instead of an opaque spinner.
    private(set) var loadProgress: String?

    init(window: NSWindow, renderer: WPEMetalSceneRenderer) {
        self.window = window
        self.renderer = renderer
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

    /// Hand the renderer out so views outside the session (e.g. the scene
    /// detail's diagnostics) can read its state without reaching through
    /// `wallpaperWindow.contentView`.
    var sceneRenderer: WPEMetalSceneRenderer? { renderer }

    /// Property-key → render-target bindings the Metal renderer exposes.
    var scenePropertyBindings: [String: [WPEScenePropertyBinding]] {
        renderer?.scenePropertyBindings ?? [:]
    }

    /// Attempts to apply a property change in place. Returns `false` when a
    /// full reload is needed.
    func applyScenePropertyPatch(_ patch: WPEScenePropertyPatch) -> Bool {
        renderer?.applyScenePropertyPatch(patch) ?? false
    }

    /// Returns the renderer when it owns its own frame-rate clock and
    /// can re-target it from the inspector's frame-rate picker.
    var frameRateController: (any WallpaperFrameRateConfigurable)? {
        renderer
    }

    /// Returns the renderer when it has a scene-owned audio engine
    /// (`WPESoundRuntime`) responsive to inspector mute/volume changes.
    /// Nil for renderers without sound objects.
    var audioController: (any WallpaperAudioConfigurable)? {
        renderer
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

    /// Per-screen cursor-reactivity toggle (camera parallax + pointer shaders).
    func setMouseInteractionEnabled(_ enabled: Bool) {
        renderer?.setMouseInteractionEnabled(enabled)
    }

    /// Per-screen "Interactive" toggle: makes the wallpaper window capture real
    /// clicks (steals desktop clicks while on) and routes them to the renderer.
    func setClickCaptureEnabled(_ enabled: Bool) {
        (window as? VideoWallpaperWindow)?.setWallpaperMouseInteractionEnabled(enabled)
        renderer?.setClickCaptureEnabled(enabled)
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
            await self?.runLoad(renderer)
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

    private func installProgressHandler(on renderer: WPEMetalSceneRenderer) {
        renderer.onProgress = { [weak self] progress in
            self?.loadProgress = progress
        }
    }

    /// Runs the Metal renderer's `load()` and records the outcome. Any failure
    /// (including `SceneRenderingError.metalRendererUnsupported`) surfaces as
    /// `loadError`.
    private func runLoad(_ renderer: WPEMetalSceneRenderer) async {
        do {
            try await renderer.load()
            guard !Task.isCancelled else { return }
            loadError = nil
            loadProgress = nil
        } catch is CancellationError {
            return
        } catch let error as SceneRenderingError {
            guard !Task.isCancelled else { return }
            Logger.warning(
                "Scene wallpaper load failed: \(error.errorDescription ?? "(no description)")",
                category: .screenManager
            )
            loadError = error
        } catch {
            guard !Task.isCancelled else { return }
            Logger.warning(
                "Scene wallpaper load failed: \(error.localizedDescription)",
                category: .screenManager
            )
            if let diagnostic = renderer.loadDiagnostics {
                loadError = .resourceFailed(diagnostic)
            } else {
                loadError = .parseFailed(error.localizedDescription)
            }
        }
    }
}
#endif
