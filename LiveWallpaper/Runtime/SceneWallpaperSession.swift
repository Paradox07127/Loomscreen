#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperVideoWeb

/// Adapter that exposes a WPE scene renderer to
/// `ScreenManager` through the shared `WallpaperRuntimeSession` protocol so
/// the rest of the runtime stack does not need a scene-specific code path.
@MainActor
final class SceneWallpaperSession: WallpaperRuntimeSession, WallpaperPlaybackControllable {
    let wallpaperType: WallpaperType = .scene

    private var window: NSWindow?
    private var renderer: WPEMetalSceneRenderer?
    private var currentProfile: WallpaperPerformanceProfile = .quality
    /// Durable user play/pause intent, mirrored on `VideoWallpaperSession`. The
    /// effective render state is `userIntendsToPlay && currentProfile == .quality`,
    /// so a manual pause survives policy refreshes and a policy suspend never
    /// clears the user's intent.
    private(set) var userIntendsToPlay = true
    private var isVisible = true
    private var didStartLoad = false
    private var loadTask: Task<Void, Never>?
    /// Monotonic id of the most recent load/reload. Guards the "clear
    /// `loadTask` when done" writes so a finished older task can't drop the
    /// handle of a newer one that replaced it while the older was draining.
    private var loadGeneration = 0
    private(set) var loadError: SceneRenderingError?
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
        } else if currentProfile == .suspended || !userIntendsToPlay {
            activity = .paused
        } else {
            activity = .active
        }
        return WallpaperSessionSummary(
            wallpaperType: .scene,
            activity: activity,
            supportsPlaybackControl: true,
            subtitle: loadError?.errorDescription.map(PIISanitizer.scrub)
        )
    }

    var isPlaying: Bool {
        isVisible && userIntendsToPlay && currentProfile == .quality
    }

    func play() {
        userIntendsToPlay = true
        applyPerformanceProfile(currentProfile)
    }

    func pause() {
        userIntendsToPlay = false
        applyPerformanceProfile(currentProfile)
    }

    var videoPlayer: WallpaperVideoPlayer? { nil }
    var wallpaperWindow: NSWindow? { window }

    var sceneRenderer: WPEMetalSceneRenderer? { renderer }

    var scenePropertyBindings: [String: [WPEScenePropertyBinding]] {
        renderer?.scenePropertyBindings ?? [:]
    }

    /// Returns `false` when a full reload is needed.
    func applyScenePropertyPatch(_ patch: WPEScenePropertyPatch) -> Bool {
        renderer?.applyScenePropertyPatch(patch) ?? false
    }

    var frameRateController: (any WallpaperFrameRateConfigurable)? {
        renderer
    }

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
        // Route through the session so the effective profile honours
        // `userIntendsToPlay` — a manually paused scene must not resume just
        // because it became visible again (space switch / display wake).
        applyPerformanceProfile(currentProfile)
    }

    func hide() {
        isVisible = false
        window?.orderOut(nil)
        // `isVisible == false` folds to `.suspended` inside applyPerformanceProfile.
        applyPerformanceProfile(currentProfile)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        // Effective render state folds the policy profile with the user's intent
        // and visibility: the renderer runs only when all three say "go".
        let effective: WallpaperPerformanceProfile =
            (isVisible && userIntendsToPlay && profile == .quality) ? .quality : .suspended
        renderer?.applyPerformanceProfile(effective)
    }

    /// Per-screen cursor-reactivity toggle (camera parallax + pointer shaders).
    func setMouseInteractionEnabled(_ enabled: Bool) {
        renderer?.setMouseInteractionEnabled(enabled)
    }

    /// Per-screen "Interaction" toggle: makes the wallpaper window capture real
    /// clicks (steals desktop clicks while on) and routes them to the renderer.
    func setClickCaptureEnabled(_ enabled: Bool) {
        (window as? VideoWallpaperWindow)?.setWallpaperMouseInteractionEnabled(enabled)
        renderer?.setClickCaptureEnabled(enabled)
    }

    /// Maps the shared `VideoFitMode` onto the renderer-local present transform
    /// (the renderer has no AVFoundation dependency).
    func setSceneFitMode(_ mode: VideoFitMode) {
        let present: WPEPresentFitMode
        switch mode {
        case .stretch: present = .stretch
        case .aspectFit: present = .contain
        case .aspectFill: present = .cover
        case .center: present = .center
        }
        renderer?.setPresentFitMode(present)
    }

    func cleanup() {
        loadTask?.cancel()
        loadTask = nil
        renderer?.cleanup()
        renderer = nil
        window?.close()
        window = nil
    }

    func startLoadIfNeeded() {
        guard !didStartLoad, let renderer else { return }
        didStartLoad = true
        installProgressHandler(on: renderer)
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { @MainActor [weak self] in
            await self?.runLoad(renderer)
            if let self, self.loadGeneration == generation {
                self.loadTask = nil
            }
        }
    }

    // No prepareForDisplay override: the protocol-extension default
    // (50ms warm-up) gives the Metal renderer enough lead time to present
    // its first frame before the wallpaper window is brought to screen.

    func reload() async {
        guard let renderer else {
            loadError = .cacheRootMissing
            return
        }
        // Cancel AND drain the in-flight load before touching the renderer.
        // Cancellation is cooperative: a load resumed after `renderer.reload()`
        // reset state would append its half-loaded textures/particles into the
        // new load (duplicated particle systems, torn pipelines).
        loadTask?.cancel()
        if let previous = loadTask {
            await previous.value
        }
        loadTask = nil
        installProgressHandler(on: renderer)
        loadGeneration += 1
        let generation = loadGeneration
        // Run the reload inside a tracked task so `cleanup()` can cancel a
        // reload that is still streaming assets when the session goes away.
        let task = Task { @MainActor [weak self] in
            do {
                try await renderer.reload()
                guard let self, self.loadGeneration == generation else { return }
                self.loadError = nil
                self.loadProgress = nil
            } catch is CancellationError {
                return
            } catch let error as SceneRenderingError {
                guard let self, self.loadGeneration == generation else { return }
                self.loadError = error
            } catch {
                guard let self, self.loadGeneration == generation else { return }
                if let diagnostic = renderer.loadDiagnostics {
                    self.loadError = .resourceFailed(diagnostic)
                } else {
                    self.loadError = .parseFailed(error.localizedDescription)
                }
            }
        }
        loadTask = task
        await task.value
        if loadGeneration == generation {
            loadTask = nil
        }
    }

    private func installProgressHandler(on renderer: WPEMetalSceneRenderer) {
        renderer.onProgress = { [weak self] progress in
            self?.loadProgress = progress
        }
    }

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
