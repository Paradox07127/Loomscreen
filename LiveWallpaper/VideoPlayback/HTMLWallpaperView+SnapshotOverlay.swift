import AppKit
import WebKit

extension HTMLWallpaperView {
    // MARK: - Snapshot Overlay

    /// Upper bound on the suspend-snapshot bitmap width in pixels. The overlay
    /// only shows a static last-frame stretched to the view's point size, so
    /// there's no visible gain in retaining a full backing-pixel capture — on a
    /// 5K panel that would be a ~50 MB `NSImage` held per suspended screen,
    /// working against the very memory-relief the suspend is meant to provide.
    private static let maxSuspendSnapshotWidth: CGFloat = 1920

    /// Hides the webView behind the snapshot so WebKit can stop updating the
    /// compositor surface. Generation-counted to discard stale captures that
    /// arrive after a resume.
    func captureSuspendSnapshot() {
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.afterScreenUpdates = false
        // Cap the capture to point-width (downsampled from backing pixels) and
        // an absolute ceiling so multiple high-DPI screens can't each pin a
        // full-resolution bitmap while suspended.
        let pointWidth = webView.bounds.width
        if pointWidth > 0 {
            snapshotConfig.snapshotWidth = NSNumber(
                value: Double(min(pointWidth, Self.maxSuspendSnapshotWidth))
            )
        }
        webView.takeSnapshot(with: snapshotConfig) { [weak self] image, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isCleaningUp,
                      self.mediaPlaybackSuspended,
                      self.snapshotGeneration == generation,
                      let image else { return }
                self.applySnapshotOverlay(image: image)
            }
        }
    }

    private func applySnapshotOverlay(image: NSImage) {
        snapshotOverlay.image = image
        snapshotOverlay.frame = bounds
        snapshotOverlay.isHidden = false
        webView.isHidden = true
    }

    func hideSnapshotOverlay() {
        snapshotOverlay.isHidden = true
        snapshotOverlay.image = nil
        webView.isHidden = false
    }
}
