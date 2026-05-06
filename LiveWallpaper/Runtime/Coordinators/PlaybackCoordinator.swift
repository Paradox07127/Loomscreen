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
    private let powerMonitor: any PowerMonitoring
    private let fullScreenDetector: any FullScreenDetecting
    private let powerPolicy: PowerPolicyController
    /// Hook into ScreenManager-owned effect application — kept as a callback
    /// because `applyVideoEffects` reaches into Combine lifetimes that aren't
    /// part of this coordinator's responsibility yet.
    private let applyVideoEffects: @MainActor (Screen, ScreenConfiguration) -> Void
    /// Hook for ScreenManager's cached `CGDisplayCopyDisplayMode` lookup —
    /// avoids re-implementing the cache or paying its cost on every setter.
    private let refreshRateLookup: @MainActor (CGDirectDisplayID) -> Int
    /// Snapshot of the current registered screens; matches
    /// `ScreenManager.screens` so the coordinator can resolve a live
    /// reference after async work returns.
    private let screensProvider: @MainActor () -> [Screen]
    /// Hook into `ScreenManager.markWallpaperSessionStateChanged` — used by
    /// the deferred autoplay path so the inspector / sidebar refresh after
    /// the policy decides to start playback.
    private let markSessionStateChanged: @MainActor () -> Void

    init(
        configurationStore: WallpaperConfigurationStore,
        powerMonitor: any PowerMonitoring,
        fullScreenDetector: any FullScreenDetecting,
        powerPolicy: PowerPolicyController,
        applyVideoEffects: @MainActor @escaping (Screen, ScreenConfiguration) -> Void,
        refreshRateLookup: @MainActor @escaping (CGDirectDisplayID) -> Int,
        screensProvider: @MainActor @escaping () -> [Screen],
        markSessionStateChanged: @MainActor @escaping () -> Void
    ) {
        self.configurationStore = configurationStore
        self.powerMonitor = powerMonitor
        self.fullScreenDetector = fullScreenDetector
        self.powerPolicy = powerPolicy
        self.applyVideoEffects = applyVideoEffects
        self.refreshRateLookup = refreshRateLookup
        self.screensProvider = screensProvider
        self.markSessionStateChanged = markSessionStateChanged
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

    // MARK: - Asset readiness + startup playback policy

    func applyConfigurationWhenAssetReady(
        player: WallpaperVideoPlayer,
        screen: Screen,
        configuration: ScreenConfiguration
    ) {
        let screenID = screen.id
        transition.cancelAssetReadiness(for: screenID)

        let apply: @MainActor () -> Void = { [weak self] in
            guard let self,
                  let liveScreen = self.screensProvider().first(where: { $0.id == screenID }) else { return }
            if configuration.particleEffect != .none {
                player.setParticleEffect(
                    configuration.particleEffect,
                    density: configuration.effectConfig.particleDensity
                )
            }
            if configuration.effectConfig.hasActiveEffect {
                self.applyVideoEffects(liveScreen, configuration)
            } else {
                self.applyFrameRateLimit(configuration.frameRateLimit, to: liveScreen)
            }
        }

        if player.videoFrameRate > 0 {
            apply()
            return
        }

        let work = AssetReadinessWork()
        transition.setAssetReadiness(work, for: screenID)
        var didApply = false

        let finish: @MainActor () -> Void = { [weak self, weak work] in
            guard let self, !didApply else { return }
            didApply = true
            apply()
            work?.cancel()
            if let work {
                self.transition.clearAssetReadinessIfMatch(work, for: screenID)
            }
        }

        work.frameRateSubscription = player.$videoFrameRate
            .first(where: { $0 > 0 })
            .receive(on: DispatchQueue.main)
            .sink { _ in
                finish()
            }

        work.fallbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            finish()
        }
    }

    func applyStartupPlaybackPolicy(to player: WallpaperVideoPlayer, for screen: Screen) {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let powerSource = powerMonitor.currentPowerSource
        let isHiddenByFullScreen = fullScreenDetector.isDesktopHidden(for: screen.id)

        let pauseForPower = WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: globalSettings,
            powerSource: powerSource
        )
        let pauseForFullScreen = WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: globalSettings,
            isHiddenByFullScreen: isHiddenByFullScreen
        )

        if pauseForPower {
            powerPolicy.markPausedByPower(screen.id)
        }
        if pauseForFullScreen {
            powerPolicy.markPausedByFullScreen(screen.id)
        }

        if WallpaperPolicyEngine.shouldStartVideoPaused(
            globalSettings: globalSettings,
            powerSource: powerSource,
            isHiddenByFullScreen: isHiddenByFullScreen
        ) {
            player.pause()
            return
        }

        schedulePolicyAwarePlaybackStart(to: player, screenID: screen.id)
    }

    func schedulePolicyAwarePlaybackStart(to player: WallpaperVideoPlayer, screenID: CGDirectDisplayID) {
        Task { @MainActor [weak self, weak player] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }

            guard let self, let player else { return }

            let globalSettings = SettingsManager.shared.loadGlobalSettings()
            let shouldPause = WallpaperPolicyEngine.shouldStartVideoPaused(
                globalSettings: globalSettings,
                powerSource: self.powerMonitor.currentPowerSource,
                isHiddenByFullScreen: self.fullScreenDetector.isDesktopHidden(for: screenID)
            )

            guard !shouldPause else {
                player.pause()
                return
            }

            player.play()
            self.markSessionStateChanged()
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
