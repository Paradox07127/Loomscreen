#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE

/// @MainActor forwarding surface for the WPE renderer's runtime-config protocols
/// (performance / frame-rate / audio). The session hands this out instead of the
/// bare renderer so consumers depend on the adapter, not the renderer's own
/// conformance.
///
/// M2c1b-3c: the renderer now lives inside `WPEDisplayRenderActor`, so every
/// forward is a fire-and-forget post onto that actor. The setters tolerate a
/// one-frame apply latency (the renderer reads the new value on its next frame),
/// so nothing here needs to await. Delivery goes through the actor's ordered
/// `submitConfig` channel (not a bare `Task`), so two rapid posts of the same
/// setter apply in issue order and the last write wins. Holds the actor
/// (Sendable); its lifetime matches the session's.
@MainActor
final class WPERendererConfigAdapter: WallpaperPerformanceConfigurable, WallpaperFrameRateConfigurable, WallpaperAudioConfigurable {
    private let renderActor: WPEDisplayRenderActor

    init(renderActor: WPEDisplayRenderActor) {
        self.renderActor = renderActor
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        renderActor.submitConfig(.performanceProfile(profile))
    }

    func setFrameRateLimit(_ limit: FrameRateLimit) {
        renderActor.submitConfig(.frameRateLimit(limit))
    }

    func setAdaptiveFrameRateThrottle(_ active: Bool) {
        renderActor.submitConfig(.adaptiveFrameRateThrottle(active))
    }

    func setAudioMuted(_ muted: Bool) {
        renderActor.submitConfig(.audioMuted(muted))
    }

    func setAudioVolume(_ volume: Double) {
        renderActor.submitConfig(.audioVolume(volume))
    }
}

/// Adapter that exposes a WPE scene renderer to
/// `ScreenManager` through the shared `WallpaperRuntimeSession` protocol so
/// the rest of the runtime stack does not need a scene-specific code path.
///
/// M2c1b-3c: owns the per-display render actor (which owns the renderer) rather
/// than the renderer directly. Frame-config setters fire-and-forget through the
/// adapter; diagnostics/present state are polled into `hasPresentedFrame` /
/// `rendererDiagnostics` caches so the SwiftUI inspector reads them synchronously.
@MainActor
final class SceneWallpaperSession: WallpaperRuntimeSession, WallpaperPlaybackControllable {
    let wallpaperType: WallpaperType = .scene

    private var window: NSWindow?
    /// Per-display render isolation domain (M2c1b-3c). Owns the renderer; the
    /// session drives it entirely through this actor.
    private let renderActor: WPEDisplayRenderActor
    /// The main-thread surface, held strongly so it (and the delivery shim it
    /// owns) outlive the wallpaper. The renderer only references it through the
    /// `Sendable` `surfaceControl` seam, so the session is its sole strong owner.
    private let surface: WPERenderSurface
    /// @MainActor forwarding surface for the renderer's runtime-config protocols.
    private let rendererConfigAdapter: WPERendererConfigAdapter
    /// True while a renderer is adopted (construction → cleanup). Drives the
    /// nil-when-no-renderer semantics for the frame-rate/audio controllers.
    private var hasRenderer = true
    private var currentProfile: WallpaperPerformanceProfile = .quality
    /// Durable user play/pause intent, mirrored on `VideoWallpaperSession`. The
    /// effective render state is `userIntendsToPlay && currentProfile == .quality`,
    /// so a manual pause survives policy refreshes and a policy suspend never
    /// clears the user's intent.
    private(set) var userIntendsToPlay = true
    private var isVisible = true
    private var didStartLoad = false
    private var loadTask: Task<Void, Never>?
    /// The controlled startup task (renderer adopt → initial load). Session-owned
    /// so `cleanup()` can cancel and drain it before teardown — a detached startup
    /// could otherwise adopt a renderer into an already-shut-down actor.
    private var startupTask: Task<Void, Never>?
    /// Retains the ordered teardown task spawned by `cleanup()` (which must keep a
    /// synchronous signature) so it runs to completion.
    private var cleanupTask: Task<Void, Never>?
    /// Bumped by `cleanup()`. The startup task checks it after `adopt` so a cleanup
    /// that raced the adopt skips `beginLoad` on a torn-down session.
    private var lifecycleGeneration = 0
    /// Monotonic id of the most recent load/reload. Guards the "clear
    /// `loadTask` when done" writes so a finished older task can't drop the
    /// handle of a newer one that replaced it while the older was draining.
    private var loadGeneration = 0
    private(set) var loadError: SceneRenderingError? {
        didSet {
            runtimeError = loadError.map {
                .sceneRenderingFailed(description: $0.errorDescription ?? "")
            }
        }
    }
    private(set) var loadProgress: String?
    private(set) var runtimeError: WallpaperRuntimeError? {
        didSet {
            guard oldValue != runtimeError else { return }
            onRuntimeErrorChange?()
        }
    }
    var onRuntimeErrorChange: (@MainActor () -> Void)?

    /// Cached present flag, refreshed by `pollRendererState()`. `nil` = no live
    /// renderer (inspector → .idle); `false` = renderer present, first frame not
    /// yet drawn (→ .loading); `true` = presented. Defaults to `false` because a
    /// renderer is adopted at construction.
    private(set) var hasPresentedFrame: Bool? = false
    /// Cached diagnostic snapshot for the inspector's log sheet, refreshed by
    /// `pollRendererState()` so the SwiftUI read stays synchronous.
    private(set) var rendererDiagnostics: SceneRendererDiagnostics?

    init(
        window: NSWindow,
        renderActor: WPEDisplayRenderActor,
        surface: WPERenderSurface
    ) {
        self.window = window
        self.renderActor = renderActor
        self.surface = surface
        self.rendererConfigAdapter = WPERendererConfigAdapter(renderActor: renderActor)
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

    /// Refreshes the present + diagnostics caches from the live renderer. The
    /// inspector's 0.4s poll awaits this before reading the sync accessors.
    func pollRendererState() async {
        guard let snapshot = await renderActor.rendererStateSnapshot() else {
            hasPresentedFrame = nil
            rendererDiagnostics = nil
            return
        }
        hasPresentedFrame = snapshot.hasPresentedFrame
        rendererDiagnostics = SceneRendererDiagnostics(
            loadDiagnostics: snapshot.loadDiagnostics,
            resolution: snapshot.resolution,
            shaderErrors: .init(
                count: snapshot.shaderErrorCount,
                entries: snapshot.shaderErrors.map { .init(shader: $0.shader, reason: $0.reason) }
            ),
            gpuErrors: .init(count: snapshot.gpuErrorCount, last: snapshot.gpuErrorLast)
        )
    }

    /// Async forwarder for the inspector's on-demand poster read-back.
    func captureLivePosterFromNextFrame() async -> NSImage? {
        await renderActor.captureLivePoster()
    }

    /// Direct (unfolded) profile push used only by the inspector to suspend the
    /// live renderer under Reduce Motion. Deliberately NOT the folding
    /// `applyPerformanceProfile` above: the inspector overrides play/pause intent
    /// to force a static frame.
    func applyPreviewPerformanceProfile(_ profile: WallpaperPerformanceProfile) async {
        await renderActor.applyPerformanceProfile(profile)
    }

    /// The loaded scene's property→binding map, read from the live renderer.
    func scenePropertyBindings() async -> [String: [WPEScenePropertyBinding]] {
        await renderActor.scenePropertyBindings()
    }

    /// Returns `false` when a full reload is needed.
    func applyScenePropertyPatch(_ patch: WPEScenePropertyPatch) async -> Bool {
        await renderActor.applyScenePropertyPatch(patch)
    }

    // Nil-when-no-renderer semantics preserved: consumers guard on this, and a
    // torn-down session must report no controller (mirrors the old `{ renderer }`).
    var frameRateController: (any WallpaperFrameRateConfigurable)? {
        hasRenderer ? rendererConfigAdapter : nil
    }

    var audioController: (any WallpaperAudioConfigurable)? {
        hasRenderer ? rendererConfigAdapter : nil
    }

    func updateFrame(to frame: CGRect) {
        window?.setFrame(frame, display: true)
        // The window's contentView IS the renderer's MTKView (set at build time),
        // so resize it here without reaching into the actor for `nsView`.
        window?.contentView?.frame = CGRect(origin: .zero, size: frame.size)
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
        rendererConfigAdapter.applyPerformanceProfile(effective)
    }

    /// Per-screen cursor-reactivity toggle (camera parallax + pointer shaders).
    func setMouseInteractionEnabled(_ enabled: Bool) {
        renderActor.submitConfig(.mouseInteractionEnabled(enabled))
    }

    /// Per-screen "Interaction" toggle: makes the wallpaper window capture real
    /// clicks (steals desktop clicks while on) and routes them to the renderer.
    func setClickCaptureEnabled(_ enabled: Bool) {
        (window as? VideoWallpaperWindow)?.setWallpaperMouseInteractionEnabled(enabled)
        renderActor.submitConfig(.clickCaptureEnabled(enabled))
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
        renderActor.submitConfig(.presentFitMode(present))
    }

    /// Adopt the freshly-built renderer into the actor and drive the initial load,
    /// inside a session-owned `startupTask`. Called by the builder in place of a
    /// detached task so `cleanup()` controls the adopt/load lifetime.
    func startAdoptingRenderer(_ handoff: WPERendererHandoff) {
        let generation = lifecycleGeneration
        startupTask = Task { [weak self, renderActor] in
            await renderActor.adopt(handoff.renderer)
            // If cleanup ran during the adopt hop, skip the load: the actor is being
            // (or has been) torn down. The renderer is still adopted, so cleanup's
            // teardown releases it.
            guard let self, self.isCurrentLifecycle(generation) else { return }
            await self.beginLoad()
        }
    }

    private func isCurrentLifecycle(_ generation: Int) -> Bool {
        lifecycleGeneration == generation
    }

    func cleanup() {
        // Invalidate any pending startup guard so a racing adopt won't drive a load.
        lifecycleGeneration += 1
        hasRenderer = false
        hasPresentedFrame = nil
        // M2c2: remove the display-link reconfiguration observer and invalidate the
        // link on main now, before the async teardown — so no rebuild can install a
        // link into an actor that is being shut down. No-op in `.main` mode.
        surface.stopDisplayLinkDriver()
        window?.close()
        window = nil
        let actor = renderActor
        let startup = startupTask
        let load = loadTask
        startupTask = nil
        loadTask?.cancel()
        loadTask = nil
        // Ordered teardown: cancel then DRAIN the startup/load tasks before tearing
        // the renderer down, so teardown never runs ahead of an in-flight adopt or
        // load. cleanup() keeps its sync signature; the task is retained above.
        cleanupTask = Task {
            startup?.cancel()
            await startup?.value
            await load?.value
            await actor.teardownRenderer()
            actor.shutdown()
        }
    }

    /// Install the progress handler and run the initial load through the actor.
    /// Called once by the builder AFTER it has adopted the renderer into the actor
    /// (the renderer never enters the session's region, sidestepping the `sending`
    /// churn of transferring a main-constructed object out of `@MainActor` code).
    /// The load runs inside a session-retained `loadTask` so `reload()`/`cleanup()`
    /// can cancel and drain an in-flight initial load exactly as before the flip.
    func beginLoad() async {
        guard !didStartLoad else { return }
        didStartLoad = true
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.installProgressHandler()
            await self.runLoadViaActor()
        }
        loadTask = task
        await task.value
        if loadGeneration == generation {
            loadTask = nil
        }
    }

    // No prepareForDisplay override: the protocol-extension default
    // (50ms warm-up) gives the Metal renderer enough lead time to present
    // its first frame before the wallpaper window is brought to screen.

    func retry() async {
        await reload()
    }

    func reload() async {
        guard hasRenderer else {
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
        await installProgressHandler()
        loadGeneration += 1
        let generation = loadGeneration
        // Run the reload inside a tracked task so `cleanup()` can cancel a
        // reload that is still streaming assets when the session goes away.
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.renderActor.reload()
                guard self.loadGeneration == generation else { return }
                self.loadError = nil
                self.loadProgress = nil
            } catch is CancellationError {
                return
            } catch let error as SceneRenderingError {
                guard self.loadGeneration == generation else { return }
                self.loadError = error
            } catch {
                guard self.loadGeneration == generation else { return }
                self.loadError = await self.mapLoadFailure(error)
            }
        }
        loadTask = task
        await task.value
        if loadGeneration == generation {
            loadTask = nil
        }
    }

    private func installProgressHandler() async {
        let handler: @Sendable (String) -> Void = { [weak self] progress in
            Task { @MainActor in self?.loadProgress = progress }
        }
        await renderActor.setProgressHandler(handler)
    }

    private func runLoadViaActor() async {
        do {
            try await renderActor.load()
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
            loadError = await mapLoadFailure(error)
        }
    }

    /// Folds a non-typed load error into a `SceneRenderingError`, pulling the
    /// renderer's `loadDiagnostics` (via the actor) when available.
    private func mapLoadFailure(_ error: Error) async -> SceneRenderingError {
        if let diagnostic = await renderActor.loadDiagnostics() {
            return .resourceFailed(diagnostic)
        }
        return .parseFailed(error.localizedDescription)
    }
}

/// Sendable snapshot of the renderer's diagnostic surface, bundled so the log
/// sheet reads one value and a future render actor can push one value across
/// the boundary. The shader/GPU summaries are named structs (not the renderer's
/// anonymous labeled tuples) — a stored labeled-tuple property crashed the 6.x
/// Sendable-synthesis pass, and named types read better at the call site.
struct SceneRendererDiagnostics: Sendable {
    struct ShaderErrors: Sendable {
        struct Entry: Sendable {
            let shader: String
            let reason: String
        }
        let count: Int
        let entries: [Entry]
    }
    struct GPUErrors: Sendable {
        let count: Int
        let last: String?
    }
    let loadDiagnostics: SceneLoadDiagnostic?
    let resolution: WPEResolutionDiagnosticsSnapshot
    let shaderErrors: ShaderErrors
    let gpuErrors: GPUErrors
}
#endif
