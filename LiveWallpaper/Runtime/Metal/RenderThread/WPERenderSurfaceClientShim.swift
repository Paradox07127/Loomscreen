#if !LITE_BUILD
import CoreGraphics
import Foundation
import os

/// Main-thread delivery shim between `WPERenderSurface` (the AppKit-bound MTKView
/// owner) and `WPEMetalSceneRenderer` (the frame producer). The surface's
/// `draw(in:)` and drawable-size callbacks land here; the shim funnels each one
/// through a single async hop to the main actor instead of calling the renderer
/// inline.
///
/// Why a shim (the renderer is not `WPERenderSurfaceClient` itself): `draw(in:)`
/// is an AppKit callback that is *always* on the main thread, but the renderer
/// lives inside `WPEDisplayRenderActor` (M2c1b-3c), which may be backed by a
/// dedicated render thread. The shim absorbs the hop: each surface callback is
/// delivered onto the render actor, where the renderer runs it.
///
/// Draw delivery depends on the actor's backing (passed at construction):
///
/// - `.main` backing: `draw(in:)` already runs on the actor's isolation thread
///   (the main thread), so the shim enters isolation **synchronously** via
///   `assumeIsolatedOnRenderThread` and renders inline. This restores the
///   pre-M2c invariant that `draw(in:)` returns only once the frame has been
///   produced — an async hop would have let `draw` return before the render ran.
///
/// - `.renderThread` backing: the render happens off the main actor, so the shim
///   uses an async, latest-wins hop. `draw(in:)` can fire faster than the render
///   thread drains; `frameInFlight` keeps at most one frame scheduled — a second
///   `draw` arriving while one is pending is dropped, not queued, because
///   `renderFrame` always reads the *newest* renderer state, so the already-
///   scheduled render presents it. The flag clears only once the actor finishes,
///   so a dropped draw's side effects (an appended live-poster continuation, a
///   fresh `outputTexture`) are always folded into the pending render.
@MainActor
final class WPERenderSurfaceClientShim: WPERenderSurfaceClient {
    /// The render actor to deliver onto. Weak: the actor owns the renderer, which
    /// owns this shim; this points back so it can schedule without a retain cycle.
    private weak var renderActor: WPEDisplayRenderActor?

    /// True when the actor is `.main`-backed, so `draw(in:)` renders synchronously.
    private let synchronousDraw: Bool

    /// Set while a frame render is scheduled/in flight (`.renderThread` only);
    /// test-and-set on `draw`, cleared when that render completes. An
    /// `OSAllocatedUnfairLock<Bool>` (the library's Sendable-flag idiom) so the
    /// flag is safe to touch from the render actor's completion without itself
    /// being actor-isolated state.
    private let frameInFlight = OSAllocatedUnfairLock(initialState: false)

    /// Frames the shim has finished delivering. For the synchronous (`.main`) path
    /// the increment happens inline before `renderAndPresentFrame` returns; for the
    /// async path it happens in the completion (off-main), so it is lock-backed
    /// (Sendable) rather than actor-isolated. This is the observable for the
    /// "draw returns = frame produced" invariant.
    private let completedFrameDeliveryCount = OSAllocatedUnfairLock(initialState: 0)
    var completedFrameDeliveries: Int { completedFrameDeliveryCount.withLock { $0 } }

    init(renderActor: WPEDisplayRenderActor, backing: WPEDisplayRenderActor.Backing) {
        self.renderActor = renderActor
        switch backing {
        case .main: self.synchronousDraw = true
        case .renderThread: self.synchronousDraw = false
        }
    }

    func renderAndPresentFrame() {
        guard let renderActor else { return }
        if synchronousDraw {
            // Already on the actor's isolation thread (main). Enter synchronously so
            // the frame is produced before this returns.
            renderActor.assumeIsolatedOnRenderThread { $0.renderFrame() }
            completedFrameDeliveryCount.withLock { $0 += 1 }
            return
        }
        // test-and-set: skip if a render is already scheduled (latest-wins).
        let alreadyPending = frameInFlight.withLock { pending -> Bool in
            if pending { return true }
            pending = true
            return false
        }
        if alreadyPending { return }
        Task { [weak self, renderActor] in
            await renderActor.renderFrame()
            self?.frameInFlight.withLock { $0 = false }
            self?.completedFrameDeliveryCount.withLock { $0 += 1 }
        }
    }

    func updateSurfaceGeometry(drawableSize: CGSize) {
        // Geometry is a Sendable value; deliver through the actor's ordered config
        // channel so only the latest size ever wins and it stays ordered against
        // the other config setters. No render-value dependency, so a one-frame
        // latency is fine.
        renderActor?.submitConfig(.surfaceGeometry(drawableSize))
    }
}
#endif
