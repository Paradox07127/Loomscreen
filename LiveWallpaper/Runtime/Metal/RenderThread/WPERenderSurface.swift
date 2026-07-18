#if !LITE_BUILD
import AppKit
import MetalKit
import QuartzCore

/// The single owner of the wallpaper's main-thread "surface": the
/// `WPEInteractiveMTKView`, its `MTKViewDelegate` role, the pointer `mailbox`,
/// and the `WPEPointerPublisher` that feeds it. `WPEMetalSceneRenderer` no
/// longer touches the view — it holds the mailbox + the view's `CAMetalLayer`
/// and drives pacing / redraw / present through this surface. This is the seam
/// that lets the renderer family leave `@MainActor` later (M2c1b): everything
/// AppKit-bound lives here, on main, permanently.
///
/// Ownership: the renderer holds this strongly; this holds the renderer weakly
/// (mirrors `MTKView.delegate`'s weak reference, which this also is). No cycle.
@MainActor
final class WPERenderSurface: NSObject, MTKViewDelegate {
    let mtkView: WPEInteractiveMTKView
    let mailbox: WPEPointerMailbox
    /// The view's backing `CAMetalLayer`, extracted once. Handed to the renderer
    /// as its present/drawable source so the renderer never reads the view.
    let metalLayer: CAMetalLayer

    private let publisher: WPEPointerPublisher
    /// The delivery shim. Held **strongly** (M2c1b-3c): the renderer no longer
    /// owns it — decoupling the renderer's object graph from the shim (and thus
    /// the render actor it targets) is what lets the renderer be `sending`-adopted
    /// into the actor. The surface is kept alive by the session.
    private var client: WPERenderSurfaceClient?

    // MARK: - M2c2 display-link frame driver (`.renderThread` only)
    //
    // In `.renderThread` mode the surface stops being the pacing source (its MTKView
    // stays paused) and instead owns the per-display `CADisplayLink`'s main-thread
    // lifecycle: create it for the view's current screen, rebuild it on display
    // reconfiguration, and invalidate it at teardown. The link itself lives on the
    // render thread (see `WPEDisplayRenderActor`); the surface only orchestrates
    // create/replace/stop from main. All three fields stay nil in `.main` mode.
    private weak var displayLinkActor: WPEDisplayRenderActor?
    private var displayLinkTarget: WPEDisplayLinkTarget?
    private var screenParamsObserver: NSObjectProtocol?

    init(frame: CGRect, device: MTLDevice) {
        let view = WPEInteractiveMTKView(frame: frame, device: device)
        view.wantsLayer = true
        // View config lifted verbatim from the old renderer init — the initial
        // pacing (paused, on-demand redraw, 30 FPS) the renderer expects.
        view.colorPixelFormat = WPEMetalRenderExecutor.outputPixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = WPEMetalSceneRenderer.defaultPreferredFPS
        view.autoresizingMask = [.width, .height]
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        guard let metalLayer = view.layer as? CAMetalLayer else {
            preconditionFailure("MTKView must be backed by a CAMetalLayer")
        }
        let mailbox = WPEPointerMailbox()
        self.mtkView = view
        self.mailbox = mailbox
        self.metalLayer = metalLayer
        self.publisher = WPEPointerPublisher(mailbox: mailbox, view: view)
        super.init()
        view.delegate = self
        // The view latches click/pointer state on the main thread; forward each
        // latch to the mailbox so the render path reads it without the view.
        view.onPointerFrameChange = { [mailbox] frame in
            mailbox.publishPointerFrame(frame)
        }
    }

    /// Wire the renderer and start feeding the mailbox. Idempotent publisher.
    func attach(client: WPERenderSurfaceClient) {
        self.client = client
        publisher.start()
        client.updateSurfaceGeometry(drawableSize: metalLayer.drawableSize)
    }

    // MARK: - Display-link driver lifecycle (M2c2, `.renderThread`)

    /// Stand up the CADisplayLink frame driver once the view is in a window (so it
    /// has a screen). Called by the builder after `orderBack`. Also starts watching
    /// for display reconfiguration so the link is rebuilt onto the current screen.
    func startDisplayLinkDriver(renderActor: WPEDisplayRenderActor) {
        displayLinkActor = renderActor
        displayLinkTarget = WPEDisplayLinkTarget(renderActor: renderActor)
        buildDisplayLink()
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildDisplayLink() }
        }
    }

    /// Create a link for the view's current screen and hand it to the render thread,
    /// which replaces (and invalidates) any prior one. Called for the initial attach
    /// and on every reconfiguration.
    private func buildDisplayLink() {
        guard let renderActor = displayLinkActor,
              let target = displayLinkTarget,
              let screen = mtkView.window?.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: target, selector: #selector(WPEDisplayLinkTarget.step(_:)))
        let handoff = WPEDisplayLinkHandoff(link: link)
        Task { await renderActor.replaceDisplayLink(handoff) }
    }

    /// Remove the reconfiguration observer and invalidate the live link. Idempotent
    /// (second call no-ops after `displayLinkActor` is cleared). Called from the
    /// session's `cleanup()` before renderer teardown, and again from `detachOnMain`.
    func stopDisplayLinkDriver() {
        if let screenParamsObserver {
            NotificationCenter.default.removeObserver(screenParamsObserver)
        }
        screenParamsObserver = nil
        if let renderActor = displayLinkActor {
            Task { await renderActor.invalidateCurrentDisplayLink() }
        }
        displayLinkActor = nil
        displayLinkTarget = nil
    }

    // MARK: - Pacing (driven by the renderer, via `WPESurfaceControl`)
    //
    // These are the main-thread bodies. The renderer reaches them only through
    // the nonisolated `WPESurfaceControl` seam below, which delivers each call to
    // the main thread. Kept private so every renderer call site goes through the
    // seam (the point of M2c1b: the renderer can leave `@MainActor` later).

    private func applyPacingOnMain(_ update: WPERenderPacingUpdate) {
        if let paused = update.isPaused { mtkView.isPaused = paused }
        if let enable = update.enableSetNeedsDisplay { mtkView.enableSetNeedsDisplay = enable }
        if let fps = update.preferredFramesPerSecond { mtkView.preferredFramesPerSecond = fps }
    }

    private func setNeedsRedrawOnMain() { mtkView.setNeedsDisplay(mtkView.bounds) }

    private func drawImmediatelyOnMain() { mtkView.draw() }

    private func releaseDrawablesOnMain() { mtkView.releaseDrawables() }

    /// The per-screen Interaction toggle: the view gates event capture on it, the
    /// mailbox exposes it to the render path. Both must see the same value.
    private func setClickCaptureEnabledOnMain(_ enabled: Bool) {
        mtkView.clickCaptureEnabled = enabled
        mailbox.setClickCaptureEnabled(enabled)
    }

    /// Terminal teardown body — stop the event/geometry feed and break the
    /// delegate link so no further `draw(in:)` reaches a torn-down renderer.
    private func detachOnMain() {
        stopDisplayLinkDriver()
        publisher.stop()
        mtkView.delegate = nil
        client = nil
    }

    // MARK: - MTKViewDelegate

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { [weak self] in
            self?.client?.renderAndPresentFrame()
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            self.client?.updateSurfaceGeometry(drawableSize: size)
            // The view just gained/changed its window-relative geometry; refresh
            // the mailbox so the first mailbox read after layout isn't `.none`.
            self.mailbox.publishGeometry(WPEPointerPublisher.geometry(of: self.mtkView))
        }
    }
}

/// Sendable handle to the wallpaper's present layer. `@unchecked Sendable`
/// because `CAMetalLayer` is not `Sendable`, yet `nextDrawable()`/present are
/// documented safe off the main thread and the render actor is the layer's only
/// present-time caller. Wrapping it lets the renderer hold the layer WITHOUT its
/// object graph reaching the main-thread `WPERenderSurface` — the isolation
/// pre-req for `sending` the renderer into `WPEDisplayRenderActor`. Falsifiable:
/// if present ever races the surface's own main-thread layer mutations, this seam
/// is where the sharing is deliberately unchecked.
struct WPEPresentLayer: @unchecked Sendable {
    let layer: CAMetalLayer
}

/// A partial update to the view's pacing knobs. `nil` fields are left untouched,
/// so each renderer call site writes exactly the knobs it wrote before.
struct WPERenderPacingUpdate: Sendable {
    var isPaused: Bool?
    var enableSetNeedsDisplay: Bool?
    var preferredFramesPerSecond: Int?
}

/// What the surface calls back into (the renderer). Kept a protocol so the
/// surface has no compile dependency on the concrete renderer type.
@MainActor
protocol WPERenderSurfaceClient: AnyObject {
    func renderAndPresentFrame()
    func updateSurfaceGeometry(drawableSize: CGSize)
}

/// The renderer→surface control seam (M2c1b). One method per main-thread entry
/// the renderer drove synchronously before; every method is **non-blocking
/// delivery** — callable from any thread, guaranteed to land on the main thread.
/// `Sendable` so the renderer can hold `any WPESurfaceControl` after it leaves
/// `@MainActor`. Today the sole caller is still `@MainActor`, so each call takes
/// the synchronous branch and behavior is byte-identical to the old direct calls.
protocol WPESurfaceControl: Sendable {
    func applyPacing(_ update: WPERenderPacingUpdate)
    func setNeedsRedraw()
    func drawImmediately()
    func releaseDrawables()
    func detach()
    func setClickCaptureEnabled(_ enabled: Bool)
}

extension WPERenderSurface: WPESurfaceControl {
    nonisolated func applyPacing(_ update: WPERenderPacingUpdate) {
        deliver { $0.applyPacingOnMain(update) }
    }

    nonisolated func setNeedsRedraw() {
        deliver { $0.setNeedsRedrawOnMain() }
    }

    nonisolated func drawImmediately() {
        deliver { $0.drawImmediatelyOnMain() }
    }

    nonisolated func releaseDrawables() {
        deliver { $0.releaseDrawablesOnMain() }
    }

    nonisolated func detach() {
        deliver { $0.detachOnMain() }
    }

    nonisolated func setClickCaptureEnabled(_ enabled: Bool) {
        deliver { $0.setClickCaptureEnabledOnMain(enabled) }
    }

    /// Non-blocking delivery to main: synchronous when the caller is already on
    /// the main thread — today's only path, the renderer is still `@MainActor` —
    /// so behavior is unchanged; otherwise a `@MainActor` `Task` (future callers
    /// off the render actor). Never blocks the caller.
    private nonisolated func deliver(_ body: @escaping @MainActor (WPERenderSurface) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            Task { @MainActor in body(self) }
        }
    }
}
#endif
