#if !LITE_BUILD
import AppKit
import QuartzCore

/// Drives per-display frame pacing through a display link on the render thread.
/// Main-thread backing continues to use the MTKView surface directly.

/// Target of the AppKit-vended `CADisplayLink`. Because the link is added to the
/// render thread's run loop, `step(_:)` fires there — it enters the actor's
/// isolation synchronously and produces exactly one frame, the same shape the old
/// MTKView `draw(in:)` had on the main thread. Holds the actor weakly: the link
/// retains this target and the actor retains the link, so a strong back-reference
/// would leak the actor (and with it the renderer).
final class WPEDisplayLinkTarget: NSObject {
    private weak var renderActor: WPEDisplayRenderActor?

    init(renderActor: WPEDisplayRenderActor) {
        self.renderActor = renderActor
        super.init()
    }

    @objc func step(_ link: CADisplayLink) {
        // On the render thread (the link's run loop). assumeIsolated grants sync
        // isolated access via the executor's checkIsolated — a misrouted callback
        // would trap rather than race.
        renderActor?.assumeIsolatedOnRenderThread { $0.renderFrame() }
    }
}

/// One-shot carrier handing a main-thread-created `CADisplayLink` to the render
/// actor. `@unchecked Sendable`: the link is created on main (the `NSScreen`
/// display-link API is main-only) and transferred exactly once; after
/// `replaceDisplayLink` registers it on the render run loop, only the render
/// thread touches it. Falsifiable: if the surface keeps and mutates the link
/// after handoff, or hands the same link to two actors, this is unsound.
struct WPEDisplayLinkHandoff: @unchecked Sendable {
    let link: CADisplayLink
}

/// The renderer's pacing seam in `.renderThread` mode. The four pacing/redraw
/// calls the renderer already makes (`applyPacing` / `setNeedsRedraw` /
/// `drawImmediately` / `releaseDrawables`) are rerouted here: pause + rate drive
/// the render-thread `CADisplayLink`, and a one-off redraw renders a single frame
/// on the render thread — instead of touching the now purely-hosting MTKView.
/// Click capture, drawable release, and detach still belong to the main-thread
/// surface, so those forward straight through.
///
/// Every method is invoked on the render thread: the renderer that calls them runs
/// inside the actor's isolation, so link mutation is naturally on the link's own
/// thread and `assumeIsolatedOnRenderThread` enters synchronously (no hop).
///
/// `@unchecked Sendable` (required by `WPESurfaceControl`): the only non-Sendable-
/// shaped field is `weak var renderActor` — a reference to a `Sendable` actor,
/// nil'd only by ARC; `surface` is itself a `Sendable` existential. There is no
/// other mutable state and every method runs on the render thread. Falsifiable: it
/// breaks if a non-Sendable mutable field is added or a method is called off the
/// render thread (`assumeIsolated` would trap in the latter case).
final class WPERenderThreadFramePacer: WPESurfaceControl, @unchecked Sendable {
    private weak var renderActor: WPEDisplayRenderActor?
    /// The real main-thread surface, kept behind the `Sendable` protocol so this
    /// pacer stays free of the concrete `@MainActor` view graph.
    private let surface: any WPESurfaceControl

    init(surface: any WPESurfaceControl, renderActor: WPEDisplayRenderActor) {
        self.surface = surface
        self.renderActor = renderActor
    }

    nonisolated func applyPacing(_ update: WPERenderPacingUpdate) {
        // `enableSetNeedsDisplay` is an MTKView knob; the host view stays paused,
        // so only the link's pause + rate matter here.
        renderActor?.assumeIsolatedOnRenderThread { actor in
            if let paused = update.isPaused { actor.setLinkPaused(paused) }
            if let fps = update.preferredFramesPerSecond { actor.setLinkPreferredFPS(fps) }
        }
    }

    nonisolated func setNeedsRedraw() {
        // Paused link (static scene) or one-off refresh: render exactly one frame on
        // the render thread — the single-frame effect the MTKView `setNeedsDisplay`
        // path produced.
        renderActor?.assumeIsolatedOnRenderThread { $0.renderFrame() }
    }

    nonisolated func drawImmediately() {
        // The old `mtkView.draw()` rendered synchronously before returning; entering
        // isolation on the render thread renders synchronously here too.
        renderActor?.assumeIsolatedOnRenderThread { $0.renderFrame() }
    }

    nonisolated func releaseDrawables() { surface.releaseDrawables() }

    nonisolated func detach() { surface.detach() }

    nonisolated func setClickCaptureEnabled(_ enabled: Bool) {
        surface.setClickCaptureEnabled(enabled)
    }
}
#endif
