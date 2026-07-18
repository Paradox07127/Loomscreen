#if !LITE_BUILD
import Foundation

/// Per-frame pointer inputs `renderCurrentFrame` needs, snapshotted from the
/// `WPEPointerMailbox` (fed by the surface's publisher + view) plus the
/// renderer's own effective FPS, passed in as a Sendable snapshot. This is the
/// seam for moving the render off `@MainActor` (Phase 2): the mailbox read is
/// already NSView-free, so `makeFrameInputs` no longer touches AppKit.
///
/// Renderer-private frame sources (frame clock, camera-parallax smoother, audio
/// broker, oracle override) are deliberately absent — they migrate with the
/// renderer, so `sampleFrameContext` still reads them directly.
struct WPEFrameInputs: Sendable {
    /// Mailbox `clickCaptureEnabled` — the per-screen Interaction toggle.
    let clickCaptureEnabled: Bool
    /// Result of `pointerSampler.sample()` (the mailbox pointer sample in
    /// production, a fixed value in fixtures). Sampled unconditionally here; the
    /// mouse-interaction gate stays in `sampleFrameContext` because it reads the
    /// renderer-private `mouseInteractionEnabled`, so the result is discarded
    /// downstream exactly as before when both toggles are off.
    let pointerSample: WPEMetalPointerSample
    /// Mailbox `pointerFrame` — the latched click/button state.
    let pointerFrame: WPEPointerFrame
    /// The renderer's `effectiveFPS`, used only by the audio-capture diag log.
    let preferredFramesPerSecond: Int
}
#endif
