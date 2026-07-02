#if !LITE_BUILD
import AppKit
import MetalKit
import simd

/// `MTKView` subclass that captures real mouse events for clickable WPE scenes.
///
/// Parallax (`g_PointerPosition`) only needs the *global* cursor position and
/// works independently via the renderer's global pointer sampler. Click
/// interaction is different: the wallpaper window must stop ignoring mouse
/// events (which steals desktop clicks), and the events must reach the renderer.
/// This view latches the captured pointer/button state for the per-frame uniforms.
///
/// All capture is gated on `clickCaptureEnabled`; when off, events fall through
/// to `super` (and the hosting window keeps `ignoresMouseEvents = true`, so they
/// never arrive anyway).
@MainActor
final class WPEInteractiveMTKView: MTKView {
    /// Flipped by the renderer from the per-screen "Interactive" toggle. Only
    /// while true does this view consume mouse events.
    var clickCaptureEnabled = false

    private(set) var pointerFrame: WPEPointerFrame = .neutral

    override var acceptsFirstResponder: Bool { clickCaptureEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { clickCaptureEnabled }

    /// AppKit only delivers `mouseMoved(with:)` to a view that owns a tracking
    /// area with `.mouseMoved`. Without this, hovering (no button down) never
    /// updates the captured pointer — only `mouseDragged` would. `.activeAlways`
    /// because the wallpaper window is never key; the window itself still only
    /// forwards moved events while capturing (`acceptsMouseMovedEvents`).
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Top-left-origin normalized UV of an event, matching the scene's UV
    /// convention (same flip as `WPEMetalPointerSampler.normalizedSceneUV`).
    private func uv(for event: NSEvent) -> SIMD2<Double> {
        guard bounds.width > 0, bounds.height > 0 else { return SIMD2<Double>(0.5, 0.5) }
        let local = convert(event.locationInWindow, from: nil)
        let x = Double(local.x / bounds.width)
        let y = 1.0 - Double(local.y / bounds.height)
        return SIMD2<Double>(min(max(x, 0), 1), min(max(y, 0), 1))
    }

    override func mouseDown(with event: NSEvent) {
        guard clickCaptureEnabled else { super.mouseDown(with: event); return }
        let position = uv(for: event)
        pointerFrame.position = position
        pointerFrame.clickPosition = position
        pointerFrame.isDown = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard clickCaptureEnabled else { super.mouseDragged(with: event); return }
        pointerFrame.position = uv(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard clickCaptureEnabled else { super.mouseUp(with: event); return }
        pointerFrame.position = uv(for: event)
        pointerFrame.isDown = false
    }

    override func mouseMoved(with event: NSEvent) {
        guard clickCaptureEnabled else { super.mouseMoved(with: event); return }
        pointerFrame.position = uv(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard clickCaptureEnabled else { super.rightMouseDown(with: event); return }
        pointerFrame.clickPosition = uv(for: event)
        pointerFrame.isRightDown = true
    }

    override func rightMouseUp(with event: NSEvent) {
        guard clickCaptureEnabled else { super.rightMouseUp(with: event); return }
        pointerFrame.isRightDown = false
    }
}

/// Per-frame captured pointer/button state fed into the scene uniforms. Position
/// fields are top-left-origin UV in `[0,1]`. Neutral = centered, no buttons.
struct WPEPointerFrame: Equatable, Sendable {
    var position: SIMD2<Double>
    var clickPosition: SIMD2<Double>
    var isDown: Bool
    var isRightDown: Bool

    static let neutral = WPEPointerFrame(
        position: SIMD2<Double>(0.5, 0.5),
        clickPosition: SIMD2<Double>(0.5, 0.5),
        isDown: false,
        isRightDown: false
    )
}
#endif
