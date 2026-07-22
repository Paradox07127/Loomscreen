#if !LITE_BUILD
import Foundation

/// Sendable snapshot of pointer state and effective frame rate for one render frame.
/// Renderer-private clocks, smoothing, audio, and diagnostic inputs remain actor-isolated.
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
