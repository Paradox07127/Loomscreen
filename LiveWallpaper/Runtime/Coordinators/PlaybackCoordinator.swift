import AppKit
import Foundation

/// Owns per-screen playback configuration mutations + the
/// `PlaybackTransitionRegistry` for async-transition tracking. Slice 4 of
/// Week 4 Task 4.5 — absorbs `setVideo` + `applyConfiguration` +
/// `setupVideoPlayback`, completing the playback API surface migration so
/// ScreenManager only forwards. The remaining ScreenManager-owned hooks
/// (releaseRuntimeSession, notifyWallpaperSessionChanged) remain as callbacks
/// because they touch Combine lifetimes + notification surfaces outside this
/// coordinator's responsibility.
@MainActor
final class PlaybackCoordinator {
    let transition = PlaybackTransitionRegistry()

    private let configurationStore: WallpaperConfigurationStore
    private let powerMonitor: any PowerMonitoring
    private let fullScreenDetector: any FullScreenDetecting
    private let powerPolicy: PowerPolicyController
    private let playableVideoLoader: any PlayableVideoLoading
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
    /// Tears down a screen's runtime session including video-effects cancel,
    /// asset-readiness cancel, transition bump, and power-policy cleanup.
    /// Owned by ScreenManager so the lifecycle stays single-source-of-truth.
    private let releaseRuntimeSession: @MainActor (Screen) -> Void
    /// Hook into ScreenManager's full session-changed pipeline (state version
    /// bump + summary cache refresh + playback state push + full-screen
    /// fallback re-evaluation + screensRefreshed notification).
    private let notifyWallpaperSessionChanged: @MainActor () -> Void

    init(
        configurationStore: WallpaperConfigurationStore,
        powerMonitor: any PowerMonitoring,
        fullScreenDetector: any FullScreenDetecting,
        powerPolicy: PowerPolicyController,
        playableVideoLoader: any PlayableVideoLoading,
        applyVideoEffects: @MainActor @escaping (Screen, ScreenConfiguration) -> Void,
        refreshRateLookup: @MainActor @escaping (CGDirectDisplayID) -> Int,
        screensProvider: @MainActor @escaping () -> [Screen],
        markSessionStateChanged: @MainActor @escaping () -> Void,
        releaseRuntimeSession: @MainActor @escaping (Screen) -> Void,
        notifyWallpaperSessionChanged: @MainActor @escaping () -> Void
    ) {
        self.configurationStore = configurationStore
        self.powerMonitor = powerMonitor
        self.fullScreenDetector = fullScreenDetector
        self.powerPolicy = powerPolicy
        self.playableVideoLoader = playableVideoLoader
        self.applyVideoEffects = applyVideoEffects
        self.refreshRateLookup = refreshRateLookup
        self.screensProvider = screensProvider
        self.markSessionStateChanged = markSessionStateChanged
        self.releaseRuntimeSession = releaseRuntimeSession
        self.notifyWallpaperSessionChanged = notifyWallpaperSessionChanged
    }

    // MARK: - Configuration setters

    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id),
              speed != configuration.playbackSpeed else { return }

        let previous = configuration.playbackSpeed
        configuration.playbackSpeed = speed
        save(configuration)
        screen.videoPlayer?.setPlaybackSpeed(speed)
        Logger.info("Playback speed updated for screen \(screen.id): \(previous) -> \(speed)", category: .settings)
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

        let previous = configuration.fitMode
        configuration.fitMode = fitMode
        save(configuration)
        screen.videoPlayer?.setVideoFitMode(fitMode)
        Logger.info("Fit mode updated for screen \(screen.id): \(previous.rawValue) -> \(fitMode.rawValue)", category: .settings)
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

    private func applyConfigurationWhenAssetReady(
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

    private func applyStartupPlaybackPolicy(to player: WallpaperVideoPlayer, for screen: Screen) {
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

    private func schedulePolicyAwarePlaybackStart(to player: WallpaperVideoPlayer, screenID: CGDirectDisplayID) {
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

    // MARK: - Video session lifecycle

    func setVideo(url: URL, bookmarkData: Data, for screen: Screen) {
        Logger.info("Setting video for screen \(screen.id): \(url.lastPathComponent)", category: .screenManager)

        let existing = configurationStore.get(for: screen.id)
        let isSameURL = Self.bookmarkResolves(to: url, bookmark: existing?.videoBookmarkData)

        var configuration: ScreenConfiguration
        if var prior = existing {
            prior.replacePrimaryVideo(bookmarkData: bookmarkData)
            configuration = prior
        } else {
            configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: bookmarkData)
        }
        configuration.reconcileWPEOrigin()

        if isSameURL, screen.videoPlayer != nil {
            configurationStore.save(configuration)
            applyConfiguration(configuration, to: screen, preservingState: true)
            return
        }

        let screenID = screen.id
        let generation = transition.bumpTransition(for: screenID)
        let videoLoader = playableVideoLoader
        Task {
            do {
                try await videoLoader.validatePlayableVideo(at: url)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.transition.isCurrentTransition(generation, for: screenID),
                          let liveScreen = self.screensProvider().first(where: { $0.id == screenID }) else { return }
                    self.configurationStore.save(configuration)
                    guard SettingsManager.shared.validateConfiguration(for: screenID) else {
                        Logger.error("Failed to save video configuration for screen \(screenID)", category: .screenManager)
                        if let existing {
                            self.configurationStore.save(existing)
                        } else {
                            self.configurationStore.remove(for: screenID)
                        }
                        return
                    }
                    self.setupVideoPlayback(url: url, screen: liveScreen)
                }
            } catch {
                await MainActor.run {
                    Logger.error("Failed to setup video: \(error.localizedDescription)", category: .screenManager)
                }
            }
        }
    }

    func applyConfiguration(_ configuration: ScreenConfiguration, to screen: Screen, preservingState: Bool = false) {
        do {
            guard let bookmarkData = configuration.videoBookmarkData else {
                throw NSError(domain: "ScreenManager", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "No saved video bookmark is available for this screen."
                ])
            }

            let resolution = try ResourceUtilities.resolveBookmark(bookmarkData)
            let url = resolution.url

            guard url.startAccessingSecurityScopedResource() else {
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                    throw NSError(domain: "ScreenManager", code: 403, userInfo: [
                        NSLocalizedDescriptionKey: "Cannot access the video file. Permission denied."
                    ])
                }
                return applyConfigurationForAccessibleURL(
                    url,
                    configuration: configuration,
                    screen: screen,
                    preservingState: preservingState
                )
            }
            defer { url.stopAccessingSecurityScopedResource() }

            if resolution.isStale && resolution.isSecurityScoped {
                do {
                    let updatedBookmarkData = try url.bookmarkData(
                        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    let updatedConfig = configuration.withUpdatedActiveBookmark(updatedBookmarkData)
                    save(updatedConfig)
                } catch {
                    Logger.error("Failed to update stale bookmark: \(error.localizedDescription)", category: .fileAccess)
                }
            }

            applyConfigurationForAccessibleURL(
                url,
                configuration: configuration,
                screen: screen,
                preservingState: preservingState
            )
        } catch let error as NSError {
            Logger.error("Failed to apply configuration: \(error.localizedDescription) [domain=\(error.domain) code=\(error.code)]", category: .screenManager)
            // Malformed persisted bookmark; clear it to avoid retry loops.
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadCorruptFileError {
                Logger.warning("Clearing unresolvable bookmark for screen \(screen.id); user must re-pick the source.", category: .screenManager)
                configurationStore.remove(for: screen.id)
                releaseRuntimeSession(screen)
                notifyWallpaperSessionChanged()
            }
        } catch {
            Logger.error("Failed to apply configuration: \(error.localizedDescription)", category: .screenManager)
        }
    }

    private func applyConfigurationForAccessibleURL(
        _ url: URL,
        configuration: ScreenConfiguration,
        screen: Screen,
        preservingState: Bool
    ) {
        let existingPlayer = screen.videoPlayer
        let needsNewPlayer = existingPlayer == nil || existingPlayer?.videoURL != url

        if !needsNewPlayer, let player = existingPlayer {
            let currentTime = preservingState ? player.player?.currentTime() : .zero
            let wasPlaying = player.isPlaying

            player.setVideoFitMode(configuration.fitMode)

            let currentSpeed = player.player?.defaultRate ?? 1.0
            if abs(Float(configuration.playbackSpeed) - currentSpeed) > 0.01 {
                player.setPlaybackSpeed(configuration.playbackSpeed)
            }

            if player.videoFrameRate > 0 {
                if configuration.effectConfig.hasActiveEffect {
                    applyVideoEffects(screen, configuration)
                } else {
                    applyFrameRateLimit(configuration.frameRateLimit, to: screen)
                }
            }

            if let currentTime {
                player.player?.seek(to: currentTime)
            }

            let globalSettings = SettingsManager.shared.loadGlobalSettings()
            let shouldPause = WallpaperPolicyEngine.shouldStartVideoPaused(
                globalSettings: globalSettings,
                powerSource: powerMonitor.currentPowerSource,
                isHiddenByFullScreen: fullScreenDetector.isDesktopHidden(for: screen.id)
            )

            if shouldPause {
                player.pause()
            } else if !wasPlaying {
                schedulePolicyAwarePlaybackStart(to: player, screenID: screen.id)
            }
        } else {
            if existingPlayer != nil {
                releaseRuntimeSession(screen)
            }
            let player = WallpaperVideoPlayer(
                url: url,
                frame: screen.frame,
                fitMode: configuration.fitMode
            )
            let session = VideoWallpaperSession(player: player)
            session.onRuntimeErrorChange = { [markSessionStateChanged] in markSessionStateChanged() }
            screen.installRuntimeSession(session)
            notifyWallpaperSessionChanged()

            player.setPlaybackSpeed(configuration.playbackSpeed)
            applyConfigurationWhenAssetReady(player: player, screen: screen, configuration: configuration)
            applyStartupPlaybackPolicy(to: player, for: screen)
        }

        applyPerformancePolicy(to: screen)
    }

    func setupVideoPlayback(url: URL, screen: Screen) {
        releaseRuntimeSession(screen)

        let configuration = configurationStore.get(for: screen.id)
        let player = WallpaperVideoPlayer(
            url: url,
            frame: screen.frame,
            fitMode: configuration?.fitMode ?? .aspectFill
        )

        if let stored = configuration?.muted {
            player.setMuted(stored)
        }

        guard let liveScreen = screensProvider().first(where: { $0.id == screen.id }) else {
            Logger.warning("Screen with ID \(screen.id) not found in screens array", category: .screenManager)
            return
        }

        let session = VideoWallpaperSession(player: player)
        session.onRuntimeErrorChange = { [markSessionStateChanged] in markSessionStateChanged() }
        liveScreen.installRuntimeSession(session)
        applyPerformancePolicy(to: liveScreen)

        if let configuration {
            player.setPlaybackSpeed(configuration.playbackSpeed)
            applyConfigurationWhenAssetReady(player: player, screen: liveScreen, configuration: configuration)
        }

        applyStartupPlaybackPolicy(to: player, for: liveScreen)
        Logger.info("Video player setup complete for screen \(screen.id)", category: .screenManager)
        notifyWallpaperSessionChanged()
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

    private func applyPerformancePolicy(to screen: Screen) {
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let isHiddenByFullScreen = globalSettings.pauseOnFullScreen &&
            fullScreenDetector.isDesktopHidden(for: screen.id)
        let profile = WallpaperPolicyEngine.performanceProfile(
            globalSettings: globalSettings,
            powerSource: powerMonitor.currentPowerSource,
            isHiddenByFullScreen: isHiddenByFullScreen
        )
        screen.runtimeSession?.applyPerformanceProfile(profile)
    }

    private static func bookmarkResolves(to url: URL, bookmark: Data?) -> Bool {
        guard let bookmark else { return false }
        return (try? ResourceUtilities.resolveBookmark(bookmark).url) == url
    }
}
