import AppKit
import Foundation

/// Owns per-screen playback configuration mutations + the
/// `PlaybackTransitionRegistry` for async-transition tracking. Second slice of
/// Week 4 Task 4.5 — pulls the four `update*` setters and `applyFrameRateLimit`
/// out of `ScreenManager` so the playback API surface migrates one bounded
/// chunk at a time. ScreenManager keeps its public method signatures and
/// forwards to the coordinator.
@MainActor
final class PlaybackCoordinator {
    let transition = PlaybackTransitionRegistry()

    private let configurationStore: WallpaperConfigurationStore
    /// Hook into ScreenManager-owned effect application — kept as a callback
    /// because `applyVideoEffects` reaches into Combine lifetimes that aren't
    /// part of this coordinator's responsibility yet.
    private let applyVideoEffects: @MainActor (Screen, ScreenConfiguration) -> Void
    /// Hook for ScreenManager's cached `CGDisplayCopyDisplayMode` lookup —
    /// avoids re-implementing the cache or paying its cost on every setter.
    private let refreshRateLookup: @MainActor (CGDirectDisplayID) -> Int

    init(
        configurationStore: WallpaperConfigurationStore,
        applyVideoEffects: @MainActor @escaping (Screen, ScreenConfiguration) -> Void,
        refreshRateLookup: @MainActor @escaping (CGDirectDisplayID) -> Int
    ) {
        self.configurationStore = configurationStore
        self.applyVideoEffects = applyVideoEffects
        self.refreshRateLookup = refreshRateLookup
    }

    // MARK: - Configuration setters

    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id),
              speed != configuration.playbackSpeed else { return }

        configuration.playbackSpeed = speed
        save(configuration)
        screen.videoPlayer?.setPlaybackSpeed(speed)
    }

    func updateMuted(_ muted: Bool, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id),
              muted != configuration.muted else { return }

        configuration.muted = muted
        save(configuration)
        screen.videoPlayer?.setMuted(muted)
    }

    func updateFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id),
              fitMode != configuration.fitMode else { return }

        configuration.fitMode = fitMode
        save(configuration)
        screen.videoPlayer?.setVideoFitMode(fitMode)
    }

    func updateFrameRateLimit(_ frameRateLimit: FrameRateLimit, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id) else {
            Logger.warning("Cannot update frame rate limit: No configuration found for screen \(screen.id)", category: .videoPlayer)
            return
        }
        guard frameRateLimit != configuration.frameRateLimit else { return }

        configuration.frameRateLimit = frameRateLimit
        save(configuration)
        if configuration.effectConfig.hasActiveEffect {
            applyVideoEffects(screen, configuration)
        } else {
            applyFrameRateLimit(frameRateLimit, to: screen)
        }
    }

    func applyFrameRateLimit(_ frameRateLimit: FrameRateLimit, to screen: Screen) {
        guard let player = screen.videoPlayer, player.videoFrameRate > 0 else { return }

        let screenRefreshRate = refreshRateLookup(screen.id)
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: frameRateLimit,
            videoFrameRate: player.videoFrameRate,
            screenRefreshRate: Double(screenRefreshRate)
        )

        if let limit {
            Logger.info("Applying frame rate limit of \(Int(limit)) FPS to screen \(screen.id)", category: .videoPlayer)
            player.setFrameRateLimit(limit)
        } else {
            Logger.info("Using native playback path (\(Int(player.videoFrameRate)) FPS) for screen \(screen.id)", category: .videoPlayer)
            player.setFrameRateLimit(0)
        }
    }

    // MARK: - Helpers

    private func save(_ configuration: ScreenConfiguration) {
        configurationStore.save(configuration)
        NotificationCenter.default.post(
            name: .wallpaperConfigurationDidChange,
            object: nil,
            userInfo: ["screenID": configuration.screenID]
        )
    }
}
