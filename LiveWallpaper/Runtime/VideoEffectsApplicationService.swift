import AVFoundation
import CoreGraphics

@MainActor
final class VideoEffectsApplicationService {
    private let effectsManager = VideoEffectsManager()
    private var inflightTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var generations: [CGDirectDisplayID: Int] = [:]

    func applyEffects(
        to player: WallpaperVideoPlayer,
        screenID: CGDirectDisplayID,
        config: ScreenConfiguration,
        screenRefreshRate: Int,
        noEffectsHandler: () -> Void
    ) {
        guard let playerItem = player.player?.currentItem else {
            // Expected during reload/restart while AVPlayerItem is reattaching.
            Logger.debug("Skip apply-effects: no active player for screen \(screenID) yet", category: .videoPlayer)
            return
        }

        // Cancel any in-flight build for this screen — its result would be
        // stale after a slider drag or wallpaper change.
        cancelInflight(for: screenID)

        let hasEffects = config.effectConfig.hasActiveEffect || config.effectConfig.autoTimeTint
        Logger.info("Applying effects for screen \(screenID): hasEffects=\(hasEffects)", category: .videoPlayer)

        if !hasEffects {
            noEffectsHandler()
            return
        }

        effectsManager.updateConfig(config.effectConfig)

        let effectiveFPS = FrameRateLimit.resolveCompositionFPS(
            limit: config.frameRateLimit,
            videoFrameRate: player.videoFrameRate,
            screenRefreshRate: Double(screenRefreshRate)
        )
        let safeFPS = max(1.0, effectiveFPS)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(safeFPS))

        let generation = (generations[screenID] ?? 0) &+ 1
        generations[screenID] = generation

        let task = Task { [weak self, weak player, weak playerItem] in
            do {
                guard let asset = playerItem?.asset, let self else { return }
                let composition = try await self.effectsManager.buildComposition(
                    for: asset,
                    config: config.effectConfig,
                    frameDuration: frameDuration
                )
                try Task.checkCancellation()
                await MainActor.run { [weak self, weak player] in
                    guard let self,
                          let player,
                          self.generations[screenID] == generation else { return }
                    // Route through WallpaperVideoPlayer's centralized writer: composition
                    // is propagated to every AVQueuePlayer looper item and re-bound on
                    // currentItem rotation, avoiding stale-composition errors like
                    // -12784 / -11858 from the compositor pipeline.
                    player.setVideoComposition(composition)
                    self.inflightTasks[screenID] = nil
                }
            } catch is CancellationError {
                // expected — newer apply superseded this build
            } catch {
                await MainActor.run { [weak self] in
                    Logger.error("Failed to apply video effects: \(error.localizedDescription)", category: .videoPlayer)
                    // Clear inflightTasks on the error path too, so Task references don't leak.
                    self?.inflightTasks[screenID] = nil
                }
            }
        }
        inflightTasks[screenID] = task
    }

    func cancelInflight(for screenID: CGDirectDisplayID) {
        inflightTasks[screenID]?.cancel()
        inflightTasks[screenID] = nil
    }

    func cancelAll() {
        for task in inflightTasks.values { task.cancel() }
        inflightTasks.removeAll()
    }
}
