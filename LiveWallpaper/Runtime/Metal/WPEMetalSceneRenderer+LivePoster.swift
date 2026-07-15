#if !LITE_BUILD
import AppKit
import MetalKit

extension WPEMetalSceneRenderer {

    // MARK: - Capture batch

    final class LivePosterCaptureBatch: Sendable {
        weak let renderer: WPEMetalSceneRenderer?
        let captures: [UUID: CheckedContinuation<NSImage?, Never>]
        let generation: Int
        let snapshotter: WPEMetalTextureSnapshotter

        @MainActor
        init(
            renderer: WPEMetalSceneRenderer,
            captures: [UUID: CheckedContinuation<NSImage?, Never>]
        ) {
            self.renderer = renderer
            self.captures = captures
            self.generation = renderer.loadGeneration
            self.snapshotter = renderer.snapshotter
        }

        func captureAfterPresent(
            from texture: MTLTexture,
            completed: Bool,
            releaseSource: @escaping @Sendable () -> Void
        ) {
            let source = WPEMetalTextureSnapshotter.SnapshotSource(texture: texture)
            let snapshotter = snapshotter
            if !completed {
                Logger.info("[live-poster] present command buffer not completed — poster skipped", category: .wpeRender)
            }
            Task { [self, snapshotter] in
                let image = completed ? await snapshotter.snapshotAsync(from: source) : nil
                releaseSource()
                await MainActor.run {
                    let result = renderer?.loadGeneration == generation ? image : nil
                    finish(image: result)
                }
            }
        }

        func finish(image: NSImage?) {
            for continuation in captures.values {
                continuation.resume(returning: image)
            }
        }
    }
    // MARK: - Capture requests

    /// Read-back of the first frame, captured at the end of `performLoad()`
    /// **only when scene-debug artifacts are enabled**. Production leaves it
    /// `nil`; the inspector requests a poster from the next normally-presented
    /// frame via `captureLivePosterFromNextFrame()`.
    var previewSnapshot: NSImage? { cachedSnapshot }

    /// Reuses the next frame the renderer was already going to present as the
    /// inspector poster. This deliberately avoids forcing a fresh synchronous
    /// `renderCurrentFrame()` on the main actor. Dynamic scenes resolve on their
    /// next natural frame; static scenes re-present the retained output texture.
    func captureLivePosterFromNextFrame() async -> NSImage? {
        guard didLoad, hasPresentedFrame, renderPipeline != nil, currentProfile == .quality else {
            Logger.info(
                "[live-poster] skipped: didLoad=\(didLoad) presented=\(hasPresentedFrame) pipeline=\(renderPipeline != nil) profile=\(String(describing: currentProfile))",
                category: .wpeRender
            )
            return nil
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingLivePosterCaptures[id] = continuation
                requestLivePosterCaptureFrame()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishLivePosterCapture(id: id, image: nil)
            }
        }
    }

    private func requestLivePosterCaptureFrame() {
        if needsContinuousFrames {
            mtkView.setNeedsDisplay(mtkView.bounds)
        } else if outputTexture != nil {
            mtkView.draw()
        } else {
            mtkView.setNeedsDisplay(mtkView.bounds)
        }
    }

    // MARK: - Frame-time drain & completion

    func takePendingLivePosterCaptures() -> LivePosterCaptureBatch? {
        guard !pendingLivePosterCaptures.isEmpty else { return nil }
        let captures = pendingLivePosterCaptures
        pendingLivePosterCaptures.removeAll(keepingCapacity: true)
        return LivePosterCaptureBatch(renderer: self, captures: captures)
    }

    nonisolated private static func capturePendingLivePostersAfterPresent(
        _ batch: LivePosterCaptureBatch,
        from texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        releaseSource: @escaping @Sendable () -> Void
    ) {
        batch.captureAfterPresent(
            from: texture,
            completed: commandBuffer.status == .completed,
            releaseSource: releaseSource
        )
    }

    static func livePosterPresentCompletion(
        for batch: LivePosterCaptureBatch?
    ) -> (@Sendable (MTLTexture, MTLCommandBuffer, @escaping @Sendable () -> Void) -> Void)? {
        guard let batch else { return nil }
        return { source, commandBuffer, releaseSource in
            Self.capturePendingLivePostersAfterPresent(
                batch,
                from: source,
                commandBuffer: commandBuffer,
                releaseSource: releaseSource
            )
        }
    }

    private func finishLivePosterCapture(id: UUID, image: NSImage?) {
        guard let continuation = pendingLivePosterCaptures.removeValue(forKey: id) else { return }
        continuation.resume(returning: image)
    }

    func finishAllPendingLivePosterCaptures(image: NSImage?) {
        guard !pendingLivePosterCaptures.isEmpty else { return }
        let captures = pendingLivePosterCaptures
        pendingLivePosterCaptures.removeAll(keepingCapacity: false)
        LivePosterCaptureBatch(renderer: self, captures: captures).finish(image: image)
    }

    static func finishLivePosterCaptures(
        _ batch: LivePosterCaptureBatch?,
        image: NSImage?
    ) {
        batch?.finish(image: image)
    }
}
#endif
