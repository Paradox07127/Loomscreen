import AppKit
import SpriteKit
import SwiftUI

/// SwiftUI bridge for previewing the SpriteKit-backed scene. CRITICAL: this
/// host does NOT re-parent the live wallpaper's SKView — that view belongs to
/// the wallpaper window on the desktop. Reparenting it into the inspector
/// would silently strip the wallpaper from the desktop, leaving a black
/// rectangle behind and breaking the whole "set scene wallpaper" UX.
///
/// Instead we mount a separate `SKView` and present a *snapshot* of the
/// controller's scene graph. SpriteKit's `SKScene.copy()` deep-copies the
/// node tree but keeps texture references alive, so the inspector preview
/// stays in sync with what the controller is showing without competing for
/// the same view ownership.
@MainActor
struct ScenePreviewContainer: NSViewRepresentable {
    let controller: SceneRenderingController

    func makeNSView(context: Context) -> SKView {
        let view = SKView(frame: .zero)
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.preferredFramesPerSecond = SceneRenderingController.defaultPreferredFPS
        view.presentScene(snapshotScene())
        return view
    }

    func updateNSView(_ nsView: SKView, context: Context) {
        // Re-snapshot on update so the inspector reflects scene changes.
        // `presentScene(nil)` first to avoid a transient half-rendered frame.
        if let scene = snapshotScene() {
            nsView.presentScene(nil)
            nsView.presentScene(scene)
        }
    }

    /// Deep-copies the controller's live `SKScene`. Returns nil before the
    /// controller has finished `load()` — caller renders a placeholder until
    /// the snapshot becomes available.
    private func snapshotScene() -> SKScene? {
        guard let live = controller.view.scene,
              let copy = live.copy() as? SKScene else { return nil }
        copy.isPaused = live.isPaused
        return copy
    }
}
