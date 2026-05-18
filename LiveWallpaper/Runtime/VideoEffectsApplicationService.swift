import AVFoundation
import CoreGraphics

@MainActor
final class VideoEffectsApplicationService {
    private let effectsManager = VideoEffectsManager()
    private var inflightTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var generations: [CGDirectDisplayID: Int] = [:]
    /// Hash of (effectConfig, frameRateLimit) most recently APPLIED for each
    /// screen. When a duplicate apply request arrives with the same hash we
    /// skip the rebuild — `setVideoComposition` would otherwise recompile
    /// the CIFilter chain and force the AVPlayerLooper to rebind every queue
    /// item, which produced visible GPU spikes on rapid slider drags.
    private struct AppliedFingerprint: Equatable {
        let effects: VideoEffectConfig
        let limit: FrameRateLimit
    }
    private var appliedFingerprints: [CGDirectDisplayID: AppliedFingerprint] = [:]

    func applyEffects(
        to player: WallpaperVideoPlayer,
        screenID: CGDirectDisplayID,
        config: ScreenConfiguration,
        screenRefreshRate: Int,
        noEffectsHandler: () -> Void
    ) {
        guard let playerItem = player.player?.currentItem else {
            Logger.debug("Skip apply-effects: no active player for screen \(screenID) yet", category: .videoPlayer)
            return
        }

        let hasEffects = config.effectConfig.hasActiveEffect
        let fingerprint = AppliedFingerprint(effects: config.effectConfig, limit: config.frameRateLimit)

        if hasEffects, appliedFingerprints[screenID] == fingerprint, inflightTasks[screenID] == nil {
            Logger.debug("Skip apply-effects: fingerprint unchanged for screen \(screenID)", category: .videoPlayer)
            return
        }

        cancelInflight(for: screenID)

        Logger.info("Applying effects for screen \(screenID): hasEffects=\(hasEffects)", category: .videoPlayer)

        if !hasEffects {
            appliedFingerprints[screenID] = nil
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
                    player.setVideoComposition(composition)
                    self.inflightTasks[screenID] = nil
                    self.appliedFingerprints[screenID] = AppliedFingerprint(
                        effects: config.effectConfig,
                        limit: config.frameRateLimit
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    Logger.error("Failed to apply video effects: \(error.localizedDescription)", category: .videoPlayer)
                    self?.inflightTasks[screenID] = nil
                }
            }
        }
        inflightTasks[screenID] = task
    }

    func cancelInflight(for screenID: CGDirectDisplayID) {
        inflightTasks[screenID]?.cancel()
        inflightTasks[screenID] = nil
        appliedFingerprints[screenID] = nil
    }
}
