#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import MetalKit

extension WPEMetalSceneRenderer {

    // MARK: - Capture batch

    /// Sendable because it holds the render actor (Sendable) and value types only —
    /// never the non-Sendable renderer. The present-completion callback fires on a
    /// GPU thread, so this must cross threads; it re-enters the actor to check the
    /// scene is still current before delivering the poster.
    final class LivePosterCaptureBatch: Sendable {
        let actor: WPEDisplayRenderActor
        let captures: [UUID: CheckedContinuation<NSImage?, Never>]
        let generation: Int
        let snapshotter: WPEMetalTextureSnapshotter

        init(
            actor: WPEDisplayRenderActor,
            captures: [UUID: CheckedContinuation<NSImage?, Never>],
            generation: Int,
            snapshotter: WPEMetalTextureSnapshotter
        ) {
            self.actor = actor
            self.captures = captures
            self.generation = generation
            self.snapshotter = snapshotter
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
                let stillCurrent = await actor.isCurrentLoadGeneration(generation)
                finish(image: stillCurrent ? image : nil)
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
    func captureLivePosterFromNextFrame(on actor: isolated WPEDisplayRenderActor) async -> NSImage? {
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
            Task { [actor] in
                await actor.finishLivePosterCapture(id: id, image: nil)
            }
        }
    }

    private func requestLivePosterCaptureFrame() {
        if needsContinuousFrames {
            surfaceControl.setNeedsRedraw()
        } else if outputTexture != nil {
            surfaceControl.drawImmediately()
        } else {
            surfaceControl.setNeedsRedraw()
        }
    }

    // MARK: - Frame-time drain & completion

    func takePendingLivePosterCaptures() -> LivePosterCaptureBatch? {
        guard !pendingLivePosterCaptures.isEmpty, let actor = displayActor else { return nil }
        let captures = pendingLivePosterCaptures
        pendingLivePosterCaptures.removeAll(keepingCapacity: true)
        return LivePosterCaptureBatch(
            actor: actor,
            captures: captures,
            generation: loadGeneration,
            snapshotter: snapshotter
        )
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

    func finishLivePosterCapture(id: UUID, image: NSImage?) {
        guard let continuation = pendingLivePosterCaptures.removeValue(forKey: id) else { return }
        continuation.resume(returning: image)
    }

    func finishAllPendingLivePosterCaptures(image: NSImage?) {
        guard !pendingLivePosterCaptures.isEmpty else { return }
        let captures = pendingLivePosterCaptures
        pendingLivePosterCaptures.removeAll(keepingCapacity: false)
        for continuation in captures.values {
            continuation.resume(returning: image)
        }
    }

    static func finishLivePosterCaptures(
        _ batch: LivePosterCaptureBatch?,
        image: NSImage?
    ) {
        batch?.finish(image: image)
    }
}
#endif
