import AVFoundation
import CoreGraphics
import LiveWallpaperCore

@MainActor
final class VideoEffectsApplicationService {
    typealias CompositionBuilder = @MainActor (
        _ asset: AVAsset,
        _ config: VideoEffectConfig,
        _ frameDuration: CMTime
    ) async throws -> AVVideoComposition
    typealias AssetProvider = @MainActor (WallpaperVideoPlayer) -> AVAsset?

    private let effectsManager = VideoEffectsManager()
    private let compositionBuilder: CompositionBuilder?
    private let assetProvider: AssetProvider
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

    init(
        compositionBuilder: CompositionBuilder? = nil,
        assetProvider: @escaping AssetProvider = { $0.player?.currentItem?.asset }
    ) {
        self.compositionBuilder = compositionBuilder
        self.assetProvider = assetProvider
    }

    func hasInflightTask(for screenID: CGDirectDisplayID) -> Bool {
        inflightTasks[screenID] != nil
    }

    func applyEffects(
        to player: WallpaperVideoPlayer,
        screenID: CGDirectDisplayID,
        config: ScreenConfiguration,
        screenRefreshRate: Int,
        noEffectsHandler: () -> Void
    ) {
        guard let asset = assetProvider(player) else {
            Logger.debug("Skip apply-effects: no active player for screen \(screenID) yet", category: .videoPlayer)
            return
        }
        // Force SDR owns the `videoComposition` slot (Rec.709 tone-mapping).
        // Writing a CIFilter composition over it would silently disable the
        // SDR conversion the user asked for.
        if player.isForceSDRActive {
            Logger.debug("Skip apply-effects: Force SDR owns videoComposition for screen \(screenID)", category: .videoPlayer)
            cancelInflight(for: screenID)
            noEffectsHandler()
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

        let task = Task { [weak self, weak player] in
            do {
                guard let self else { return }
                let composition: AVVideoComposition
                if let compositionBuilder = self.compositionBuilder {
                    composition = try await compositionBuilder(asset, config.effectConfig, frameDuration)
                } else {
                    composition = try await self.effectsManager.buildComposition(
                        for: asset,
                        config: config.effectConfig,
                        frameDuration: frameDuration
                    )
                }
                try Task.checkCancellation()
                await MainActor.run { [weak self, weak player] in
                    guard let self, self.generations[screenID] == generation else { return }
                    self.inflightTasks[screenID] = nil
                    guard let player, !player.isForceSDRActive else { return }
                    player.setVideoComposition(composition)
                    self.appliedFingerprints[screenID] = AppliedFingerprint(
                        effects: config.effectConfig,
                        limit: config.frameRateLimit
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generations[screenID] == generation else { return }
                    Logger.error("Failed to apply video effects: \(error.localizedDescription)", category: .videoPlayer)
                    self.inflightTasks[screenID] = nil
                }
            }
        }
        inflightTasks[screenID] = task
    }

    func cancelInflight(for screenID: CGDirectDisplayID) {
        inflightTasks[screenID]?.cancel()
        inflightTasks[screenID] = nil
        // Cancellation can race a completion that already passed its final
        // Task.checkCancellation() and is queued for MainActor. Bump the token
        // as well so that queued closure cannot install a composition after
        // session/termination teardown.
        generations[screenID] = (generations[screenID] ?? 0) &+ 1
        appliedFingerprints[screenID] = nil
    }
}
