import Foundation
import QuartzCore
#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
#endif

/// Per-display render isolation domain. One instance per `NSScreen`. Its isolation
/// runs either on a dedicated `WPERenderThread` (via a custom `SerialExecutor`,
/// SE-0392) or on the main run loop, chosen at construction by `Backing` — the
/// M2c1 `WPEOffMainRenderFlag` picks it. `.renderThread` moves frame work off the
/// main actor; `.main` keeps it on the main thread through the identical code
/// path. M2c attaches the display link and moves the draw call here.
actor WPEDisplayRenderActor {

    /// Which thread this actor's isolation runs on. The M2c1 flag
    /// (`WPEOffMainRenderFlag`) picks the backing; both modes drive the exact
    /// same isolated code path, so the backing thread is the only variable.
    enum Backing {
        /// The main run loop — the flag-off default. The actor is main-isolated
        /// (its `unownedExecutor` is `MainActor`'s), so every hop into isolation
        /// stays on the main thread exactly as the pre-migration renderer did.
        case main
        /// A dedicated `WPERenderThread`, moving frame work off the main actor.
        case renderThread
    }

    /// Non-nil only for `.renderThread` backing; `.main` reuses `MainActor`'s
    /// executor and the process main run loop, so it owns no thread of its own.
    private let thread: WPERenderThread?
    private let executor: WPERenderThreadExecutor?

    nonisolated let unownedExecutor: UnownedSerialExecutor

    #if !LITE_BUILD
    /// The scene renderer this display owns (M2c1b-3c). Held as isolated state:
    /// the renderer is non-`Sendable` and now lives entirely inside this actor's
    /// isolation. It is reached only through the `withRenderer*` entries (sync
    /// frame path / setters / diagnostics) or the renderer's own async methods,
    /// which take `isolated WPEDisplayRenderActor` so they run on this actor.
    /// Constructed on the main thread and `sending`-adopted here (see `adopt`).
    private var renderer: WPEMetalSceneRenderer?

    /// FIFO delivery channel for fire-and-forget config/geometry setters. Replaces
    /// the old per-setter `Task { await … }` deliveries whose scheduling order was
    /// undefined — two rapid `setAudioVolume` posts could apply out of order and
    /// leave the renderer on the stale value. A single continuation + single
    /// consumer applies every command in submission order, so the last write always
    /// wins. `nonisolated let` so setters on any thread can `yield` without a hop.
    private nonisolated let configContinuation: AsyncStream<WPERendererConfigCommand>.Continuation
    /// The consumer side, drained by `configConsumerTask` (started in `adopt`, since
    /// config is meaningless before a renderer is present; commands submitted before
    /// then buffer and apply once draining begins).
    private let configStream: AsyncStream<WPERendererConfigCommand>
    /// Drains `configStream` in order. Ended by finishing the continuation in
    /// `shutdown()` / `deinit`. Holds `self` only weakly, so a dropped actor still
    /// deinits (its safety-net `thread?.shutdown()` still runs).
    private var configConsumerTask: Task<Void, Never>?
    #endif

    /// Defaults to `.renderThread` so existing render-thread call sites and tests
    /// keep their dedicated-thread semantics; the flag-driven display construction
    /// passes `WPEOffMainRenderFlag.backing` explicitly.
    init(label: String = "com.livewallpaper.render", backing: Backing = .renderThread) {
        switch backing {
        case .renderThread:
            let thread = WPERenderThread(label: label)
            let executor = WPERenderThreadExecutor(thread: thread)
            self.thread = thread
            self.executor = executor
            self.unownedExecutor = executor.asUnownedSerialExecutor()
        case .main:
            self.thread = nil
            self.executor = nil
            // Making the actor main-isolated at runtime: hops into isolation run
            // on the main thread, so the flag-off path is byte-for-byte the old
            // main-thread render with no separate thread to schedule or join.
            self.unownedExecutor = MainActor.sharedUnownedExecutor
        }
        #if !LITE_BUILD
        (self.configStream, self.configContinuation) = AsyncStream.makeStream(
            of: WPERendererConfigCommand.self
        )
        // The consumer is started in `adopt` — an actor init is nonisolated and
        // cannot spawn a task that captures `self` and also assigns an isolated
        // stored property.
        #endif
    }

    deinit {
        #if !LITE_BUILD
        // End the config consumer so it doesn't outlive the actor.
        configContinuation.finish()
        #endif
        // Safety net so a dropped actor never leaks its thread. Idempotent with an
        // explicit M2c `shutdown()`; a no-op if already stopped (or main-backed).
        thread?.shutdown()
    }

    // MARK: - Isolated entry points

    /// Run `body` inside the actor's isolation (on the render thread). Awaiting this
    /// from outside hops onto the render thread; `body` receives `isolated self` so
    /// it can touch isolated state synchronously.
    func run<T: Sendable>(_ body: @Sendable (isolated WPEDisplayRenderActor) throws -> T) rethrows -> T {
        try body(self)
    }

    /// Synchronous entry for callbacks that are *already* on the render thread
    /// (M2c's `CADisplayLink` selector fires here because the link is added to this
    /// thread's run loop). `assumeIsolated` verifies that via the executor's
    /// `checkIsolated()` and then grants synchronous isolated access without a hop.
    ///
    /// Safety: only valid when the current thread is this actor's render thread. If
    /// it is not, `checkIsolated()` traps rather than corrupting isolated state —
    /// so a misrouted callback fails loudly instead of racing.
    nonisolated func assumeIsolatedOnRenderThread<T: Sendable>(
        _ body: (isolated WPEDisplayRenderActor) throws -> T
    ) rethrows -> T {
        // Forward `body` directly (no wrapping closure) so it matches the stdlib
        // `Actor.assumeIsolated` shape and stays callable with a plain closure.
        try assumeIsolated(body)
    }

    // MARK: - Introspection (non-crashing; usable from any thread)

    /// True when the caller runs on this actor's isolation thread. For a
    /// `.renderThread` backing that is the dedicated thread; for `.main` it is
    /// the main thread. Lets callers and tests probe isolation without the trap
    /// that `checkIsolated()` would raise.
    nonisolated var isOnRenderThread: Bool { thread?.isCurrent ?? Thread.isMainThread }

    // MARK: - Render-loop wiring (M2c surface)
    //
    // M2c creates the `CADisplayLink` on the main thread (NSScreen requires it),
    // then attaches it here so its selector fires on the render thread — where the
    // callback enters isolation via `assumeIsolatedOnRenderThread`.

    /// The run loop backing this actor's isolation. M2c may attach a main-thread
    /// created `CADisplayLink` directly (`displayLink.add(to:forMode:)`). For a
    /// `.main` backing this is the process main run loop.
    nonisolated var renderRunLoop: RunLoop { thread?.runLoop ?? .main }

    nonisolated func add(_ displayLink: CADisplayLink, forMode mode: RunLoop.Mode = .common) {
        if let thread {
            thread.add(displayLink, forMode: mode)
        } else {
            displayLink.add(to: .main, forMode: mode)
        }
    }

    nonisolated func add(_ timer: Timer, forMode mode: RunLoop.Mode = .common) {
        if let thread {
            thread.add(timer, forMode: mode)
        } else {
            RunLoop.main.add(timer, forMode: mode)
        }
    }

    // MARK: - Lifecycle

    /// Drain queued work, stop the render thread, and join. Idempotent. A no-op
    /// for a `.main` backing, which owns no thread to stop.
    nonisolated func shutdown() {
        #if !LITE_BUILD
        // Finishing the stream ends the consumer loop; further `submitConfig`
        // yields after this are ignored. Idempotent.
        configContinuation.finish()
        #endif
        thread?.shutdown()
    }

    #if !LITE_BUILD
    /// Enqueue a fire-and-forget config/geometry change. Ordered FIFO against every
    /// other `submitConfig` on this actor, so the renderer applies them in exactly
    /// the order callers issued them and the last write wins. Callable from any
    /// thread (the `@MainActor` adapter/session/shim).
    nonisolated func submitConfig(_ command: WPERendererConfigCommand) {
        configContinuation.yield(command)
    }

    /// Applies one channel command by delegating to the isolated setter bodies, so
    /// there is a single implementation of each config effect.
    private func applyConfigCommand(_ command: WPERendererConfigCommand) {
        switch command {
        case .performanceProfile(let profile): applyPerformanceProfile(profile)
        case .frameRateLimit(let limit): setFrameRateLimit(limit)
        case .adaptiveFrameRateThrottle(let active): setAdaptiveFrameRateThrottle(active)
        case .audioMuted(let muted): setAudioMuted(muted)
        case .audioVolume(let volume): setAudioVolume(volume)
        case .mouseInteractionEnabled(let enabled): setMouseInteractionEnabled(enabled)
        case .clickCaptureEnabled(let enabled): setClickCaptureEnabled(enabled)
        case .presentFitMode(let mode): setPresentFitMode(mode)
        case .surfaceGeometry(let size): updateSurfaceGeometry(drawableSize: size)
        }
    }
    #endif

    #if !LITE_BUILD
    // MARK: - Renderer ownership (M2c1b-3c)

    /// Adopt the main-thread-constructed renderer into this actor's isolation.
    /// `sending` because the renderer leaves the caller's region for good; after
    /// this the renderer is reachable only through the actor. Also back-links the
    /// actor onto the renderer (weakly) so the renderer's sync task-spawning tails
    /// (deferred audio / on-demand video / static-texture reload) can re-enter.
    func adopt(_ renderer: sending WPEMetalSceneRenderer) {
        self.renderer = renderer
        renderer.displayActor = self
        // Start draining the config channel now that there is a renderer to apply
        // commands to. Idempotent guard: adopt runs once per actor. Weak `self` so
        // the consumer never keeps a torn-down actor alive.
        guard configConsumerTask == nil else { return }
        configConsumerTask = Task { [weak self, configStream] in
            for await command in configStream {
                guard let self else { break }
                await self.applyConfigCommand(command)
            }
        }
    }

    var hasRenderer: Bool { renderer != nil }

    /// Synchronous isolated access to the renderer — the frame path, setters and
    /// diagnostic reads. `body` runs on this actor with the renderer in hand;
    /// returns `nil` when no renderer is adopted (torn down).
    func withRenderer<T: Sendable>(
        _ body: (isolated WPEDisplayRenderActor, WPEMetalSceneRenderer) throws -> T
    ) rethrows -> T? {
        guard let renderer else { return nil }
        return try body(self, renderer)
    }

    /// Async isolated access — for tails that must `await` inside the actor
    /// (on-demand video rebuild, static-texture reload publish).
    func withRendererAsync<T: Sendable>(
        _ body: (isolated WPEDisplayRenderActor, WPEMetalSceneRenderer) async throws -> T
    ) async rethrows -> T? {
        guard let renderer else { return nil }
        return try await body(self, renderer)
    }

    /// Frame delivery from the surface shim (hot path). A named method, not a
    /// `withRenderer` closure, so the surface→actor hop sends nothing.
    func renderFrame() {
        // Time the frame body ON the render thread so the QoS controller can throttle
        // the thread onto the E-cores when there's headroom. `.main` backing owns no
        // thread and must never touch the main thread's QoS, so it skips timing.
        guard let thread else {
            renderer?.renderAndPresentFrame()
            return
        }
        let start = CACurrentMediaTime()
        renderer?.renderAndPresentFrame()
        thread.noteFrameDuration(CACurrentMediaTime() - start)
    }

    // MARK: - CADisplayLink frame driver (M2c2, `.renderThread` only)
    //
    // The link is created on the main thread (the `NSScreen.displayLink` API is
    // main-only) and handed here through a one-shot carrier. From that point ALL
    // access — runloop registration, `isPaused`, `preferredFrameRateRange`,
    // `invalidate` — happens on the render thread (this actor's isolation), the
    // same thread its selector fires on. `isPaused` is the only knob Apple
    // documents as thread-safe; `preferredFrameRateRange` is not, so neither is
    // ever touched off the render thread. In `.main` mode the renderer still paces
    // the MTKView and none of this runs.

    /// The live per-display link. Isolated state: only the render thread reads or
    /// writes it. Nil until installed / after invalidation.
    private var displayLink: CADisplayLink?
    /// Buffered pacing so an install that races the first `applyPacing` still ends
    /// on the right state — both writes are serialized on this actor, and the
    /// buffer is re-applied every time a link is (re)installed.
    private var linkPaused = true
    private var linkPreferredFPS = WPEMetalSceneRenderer.defaultPreferredFPS

    /// Install a freshly-created link, replacing (and invalidating) any prior one —
    /// used for both the initial attach and a display-reconfiguration rebuild. Runs
    /// on the render thread, so it registers the link on this thread's own run loop.
    func replaceDisplayLink(_ handoff: WPEDisplayLinkHandoff) {
        displayLink?.invalidate()
        let link = handoff.link
        displayLink = link
        applyLinkPacing()
        add(link)
    }

    /// Terminal teardown of the link (cleanup / reconfiguration stop). Idempotent.
    func invalidateCurrentDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Pause knob, driven by the renderer's `applyPacing(isPaused:)`.
    func setLinkPaused(_ paused: Bool) {
        linkPaused = paused
        applyLinkPacing()
    }

    /// Rate knob, driven by the renderer's `applyPacing(preferredFramesPerSecond:)`
    /// / `effectiveFPS`. Maps the integer ceiling onto the link's frame-rate range.
    func setLinkPreferredFPS(_ fps: Int) {
        linkPreferredFPS = fps
        // Keep the QoS budget on the live cadence so a 30fps wallpaper isn't judged
        // against a 60fps frame budget. Runs on the render thread (this actor).
        thread?.setFrameBudget(seconds: 1.0 / Double(max(fps, 1)))
        applyLinkPacing()
    }

    private func applyLinkPacing() {
        guard let displayLink else { return }
        displayLink.isPaused = linkPaused
        displayLink.preferredFrameRateRange = Self.frameRateRange(forPreferredFPS: linkPreferredFPS)
    }

    /// A fixed-cadence frame-rate range (min == max == preferred): the same
    /// "target this many FPS, let the system align to vsync divisors" contract
    /// `MTKView.preferredFramesPerSecond` used, so the presented rate is unchanged.
    static func frameRateRange(forPreferredFPS fps: Int) -> CAFrameRateRange {
        let clamped = Float(max(1, fps))
        return CAFrameRateRange(minimum: clamped, maximum: clamped, preferred: clamped)
    }

    #if DEBUG
    var linkPausedForTesting: Bool { linkPaused }
    var linkPreferredFPSForTesting: Int { linkPreferredFPS }
    var hasDisplayLinkForTesting: Bool { displayLink != nil }
    #endif

    /// Drawable-size push from the surface shim.
    func updateSurfaceGeometry(drawableSize: CGSize) {
        renderer?.updateSurfaceGeometry(drawableSize: drawableSize)
    }

    /// Runs one static-texture reload on this actor (the reload owner's task hops
    /// here to reach the renderer). Sendable-only parameters cross in.
    func performStaticReload(
        path: String,
        record: WPEMetalSceneRenderer.StaticTextureCacheRecord,
        resolver: WPEMultiRootResourceResolver,
        loader: WPEMetalTextureLoader,
        threshold: Int,
        ticket: WPEStaticTextureReloadTaskOwner.Ticket
    ) async {
        await renderer?.performStaticTextureReload(
            path: path,
            record: record,
            resolver: resolver,
            loader: loader,
            threshold: threshold,
            ticket: ticket,
            on: self
        )
    }

    /// Land completed off-thread lazy-`.tex` prefetch decodes now (called by each
    /// source's completion pump), instead of waiting for the next frame tick.
    func harvestLazyPrefetches() {
        guard let renderer else { return }
        for source in renderer.dynamicTextureSources.values {
            (source as? WPETexLazyAnimatedTextureSource)?.harvestCompletedPrefetches()
        }
    }

    /// Rebuild an on-demand video source that a script just revealed. Runs on this
    /// actor; reaches the renderer + its sources through `self`.
    func rebuildOnDemandVideo(key: String, generation: Int) async {
        guard let renderer else { return }
        defer { renderer.onDemandVideoLoading.remove(key) }
        guard renderer.loadGeneration == generation else { return }
        do {
            try await renderer.loadDynamicTextureOnActor(path: key, layerName: key, on: self)
        } catch {
            Logger.warning("Scene \(renderer.descriptor.workshopID) [OnDemandVideo] rebuild failed for \(key): \(error)", category: .wpeRender)
            return
        }
        guard renderer.loadGeneration == generation,
              let source = renderer.dynamicTextureSources[key] as? WPEVideoTextureSource else { return }
        source.applyPerformanceProfile(renderer.currentProfile)
        renderer.surfaceControl.setNeedsRedraw()
    }

    /// Off-critical-path shader/pipeline pre-warm, run as a child task on this
    /// actor so it overlaps the texture/particle load's suspension points. Reaches
    /// the renderer through `self`; the caller captures only Sendable inputs.
    func prewarmShaders(pipeline: WPEPreparedRenderPipeline, textObjects: [WPESceneTextObject]) async {
        await renderer?.prewarmCustomShaders(for: pipeline, textObjects: textObjects, on: self)
    }

    /// Publish a prepared deferred-audio runtime once its off-actor `prepare` has
    /// finished, on this actor. `WPESoundRuntime` is Sendable, so the detached
    /// audio task hands it back here.
    func publishDeferredAudio(runtime: WPESoundRuntime, generation: Int, workshopID: String) {
        guard let renderer, !Task.isCancelled, renderer.loadGeneration == generation else {
            runtime.stop()
            return
        }
        runtime.setMuted(renderer.pendingAudioMuted)
        runtime.setMasterVolume(renderer.pendingAudioVolume)
        renderer.soundRuntime = runtime
        // Seed the suspend flag from the live profile so the run-state gate is
        // correct BEFORE any later mute toggle: `pause()` records isSuspended so a
        // subsequent un-mute can't start audio on a suspended wallpaper. Under
        // `.quality`, `play()` starts iff also un-muted (a muted start stays paused
        // — expected, not a failure, so nothing to log here).
        if renderer.currentProfile == .quality {
            runtime.play()
        } else {
            runtime.pause()
        }
    }

    /// Load / reload run the renderer's async pipeline on this actor (the
    /// `isolated` parameter pins them here).
    func load() async throws {
        try await renderer?.load(on: self)
        // The first post-load frames pay the lazy GLSL→MSL transpile; pin the
        // P-cores across them so warm-up isn't judged on E-core timing.
        thread?.boostRenderQoSWarmup()
    }

    func reload() async throws {
        try await renderer?.reload(on: self)
        thread?.boostRenderQoSWarmup()
    }

    /// Tear down the renderer on this actor, then drop it. Sync: `cleanup()`
    /// touches only isolated state.
    func teardownRenderer() {
        renderer?.cleanup()
        renderer = nil
    }

    // MARK: - Config forwarders (M2c1b-3c)
    //
    // Named methods rather than `withRenderer` closures: the session/adapter are
    // `@MainActor`, so a closure they build is main-isolated and cannot be sent to
    // this actor. Passing a Sendable argument to a method crosses cleanly.

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        renderer?.applyPerformanceProfile(profile)
    }

    func setFrameRateLimit(_ limit: FrameRateLimit) {
        renderer?.setFrameRateLimit(limit)
    }

    func setAdaptiveFrameRateThrottle(_ active: Bool) {
        renderer?.setAdaptiveFrameRateThrottle(active)
    }

    func setAudioMuted(_ muted: Bool) {
        renderer?.setAudioMuted(muted)
    }

    func setAudioVolume(_ volume: Double) {
        renderer?.setAudioVolume(volume)
    }

    /// The renderer's pending master audio volume (diagnostic / test read of the
    /// last applied `setAudioVolume`).
    func currentPendingAudioVolume() -> Double? {
        renderer?.pendingAudioVolume
    }

    func setMouseInteractionEnabled(_ enabled: Bool) {
        renderer?.setMouseInteractionEnabled(enabled)
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        renderer?.setClickCaptureEnabled(enabled)
    }

    func setPresentFitMode(_ mode: WPEPresentFitMode) {
        renderer?.setPresentFitMode(mode)
    }

    func scenePropertyBindings() -> [String: [WPEScenePropertyBinding]] {
        renderer?.scenePropertyBindings ?? [:]
    }

    func applyScenePropertyPatch(_ patch: WPEScenePropertyPatch) -> Bool {
        renderer?.applyScenePropertyPatch(patch) ?? false
    }

    func captureLivePoster() async -> NSImage? {
        guard let renderer else { return nil }
        return await renderer.captureLivePosterFromNextFrame(on: self)
    }

    func loadDiagnostics() -> SceneLoadDiagnostic? {
        renderer?.loadDiagnostics
    }

    /// True when the renderer's current load matches `generation` — used by the
    /// live-poster present callback to drop a stale capture.
    func isCurrentLoadGeneration(_ generation: Int) -> Bool {
        renderer?.loadGeneration == generation
    }

    /// Resume a pending live-poster capture (cancellation tail).
    func finishLivePosterCapture(id: UUID, image: NSImage?) {
        renderer?.finishLivePosterCapture(id: id, image: image)
    }

    /// Apply a measured intro→loop phase offset on this actor. `token` guards
    /// staleness (bumped by every reload/invalidate).
    func applyIntroLoopOffset(_ offset: TimeInterval?, token: Int, scriptLoadToken: WPESceneScriptInstanceLimitToken) {
        guard let renderer,
              renderer.introPhaseToken == token,
              renderer.isCurrentSceneScriptLoad(scriptLoadToken) else { return }
        renderer.introLoopOffset = offset
    }

    /// Install the session's load-progress handler on the renderer.
    func setProgressHandler(_ handler: @escaping @Sendable (String) -> Void) {
        renderer?.onProgress = handler
    }

    /// Present flag + a full diagnostic snapshot in one hop for the inspector poll.
    func rendererStateSnapshot() -> WPERendererStateSnapshot? {
        guard let renderer else { return nil }
        let shader = renderer.shaderErrorSummary
        let gpu = renderer.gpuErrorSummary
        return WPERendererStateSnapshot(
            hasPresentedFrame: renderer.hasPresentedFrame,
            loadDiagnostics: renderer.loadDiagnostics,
            resolution: renderer.resolutionDiagnostics,
            shaderErrors: shader.entries.map { .init(shader: $0.shader, reason: $0.reason) },
            shaderErrorCount: shader.count,
            gpuErrorCount: gpu.count,
            gpuErrorLast: gpu.last
        )
    }
    #endif
}

#if !LITE_BUILD
/// A fire-and-forget config/geometry change delivered through the render actor's
/// ordered channel. All payloads are `Sendable`, so a command crosses onto the
/// actor cleanly. Only the *latest* value of any field matters, and the channel's
/// FIFO delivery guarantees the renderer ends on it.
enum WPERendererConfigCommand: Sendable {
    case performanceProfile(WallpaperPerformanceProfile)
    case frameRateLimit(FrameRateLimit)
    case adaptiveFrameRateThrottle(Bool)
    case audioMuted(Bool)
    case audioVolume(Double)
    case mouseInteractionEnabled(Bool)
    case clickCaptureEnabled(Bool)
    case presentFitMode(WPEPresentFitMode)
    case surfaceGeometry(CGSize)
}

/// One-shot Sendable carrier for handing the main-thread-constructed renderer to
/// its actor. `@unchecked Sendable`: the renderer is built on the main thread and
/// transferred into the actor exactly once, before any frame or async surface
/// runs, and is never touched on the constructing thread again. Region isolation
/// cannot see through the renderer's fresh-but-isolated construction to prove the
/// hand-off is race-free, so it is asserted here. Falsifiable: if the builder ever
/// uses the renderer after wrapping it, or hands the same renderer to two actors,
/// this carrier is unsound.
struct WPERendererHandoff: @unchecked Sendable {
    let renderer: WPEMetalSceneRenderer
}

/// One-hop snapshot of the renderer's inspector-facing state, assembled on the
/// render actor so the `@MainActor` session caches it without reaching across.
struct WPERendererStateSnapshot: Sendable {
    struct ShaderError: Sendable {
        let shader: String
        let reason: String
    }
    let hasPresentedFrame: Bool
    let loadDiagnostics: SceneLoadDiagnostic?
    let resolution: WPEResolutionDiagnosticsSnapshot
    let shaderErrors: [ShaderError]
    let shaderErrorCount: Int
    let gpuErrorCount: Int
    let gpuErrorLast: String?
}
#endif
