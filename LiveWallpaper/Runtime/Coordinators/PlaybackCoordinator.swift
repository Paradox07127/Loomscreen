import AppKit
import AVFoundation
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
    /// fallback re-evaluation).
    private let notifyWallpaperSessionChanged: @MainActor () -> Void
    /// Hook for async validation / setup failures that happen before a
    /// `VideoWallpaperSession` exists to publish its own runtime error.
    private let reportRuntimeError: @MainActor (CGDirectDisplayID, WallpaperRuntimeError?) -> Void
    /// Strategy for keeping `ScreenConfiguration.wpeOrigin` consistent with
    /// the active wallpaper. Injected so Lite can swap in a no-op variant.
    private let originReconciler: any OriginReconciler

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
        notifyWallpaperSessionChanged: @MainActor @escaping () -> Void,
        reportRuntimeError: @MainActor @escaping (CGDirectDisplayID, WallpaperRuntimeError?) -> Void = { _, _ in },
        originReconciler: any OriginReconciler
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
        self.reportRuntimeError = reportRuntimeError
        self.originReconciler = originReconciler
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
        syncVideoAudioLeadership()
    }

    func updateVideoVolume(_ volume: Double, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id) else { return }
        let clampedVolume = Self.clampedVideoVolume(volume)
        guard abs(configuration.videoVolume - clampedVolume) > 0.001 else { return }

        configuration.videoVolume = clampedVolume
        save(configuration)
        syncVideoAudioLeadership()
    }

    func updateVideoColorSpace(_ colorSpace: VideoColorSpace, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id),
              configuration.videoColorSpace != colorSpace else { return }
        configuration.videoColorSpace = colorSpace
        save(configuration)
        screen.videoPlayer?.setVideoColorSpace(colorSpace)
    }

    func refreshVideoAudioLeadership() {
        syncVideoAudioLeadership()
        applyVideoSpanLayout()
    }

    func refreshVideoRendering() {
        syncVideoAudioLeadership()
        applyVideoSpanLayout()
    }

    func updateVideoDisplayMode(_ mode: VideoDisplayMode, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id),
              configuration.videoDisplayMode != mode else { return }

        configuration.videoDisplayMode = mode
        save(configuration)
        applyVideoSpanLayout()
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

        let previousContent = existing?.activeWallpaper
        var configuration: ScreenConfiguration
        if var prior = existing {
            prior.replacePrimaryVideo(bookmarkData: bookmarkData)
            configuration = prior
        } else {
            configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: bookmarkData)
        }
        originReconciler.reconcile(
            &configuration,
            event: .userReplacedActiveWallpaper(previous: previousContent)
        )

        if isSameURL, screen.videoPlayer != nil {
            configurationStore.save(configuration)
            applyConfiguration(configuration, to: screen, preservingState: true)
            reportRuntimeError(screen.id, nil)
            return
        }

        let screenID = screen.id
        let generation = transition.bumpTransition(for: screenID)
        let videoLoader = playableVideoLoader
        reportRuntimeError(screenID, nil)
        let task = Task {
            do {
                try Task.checkCancellation()
                try await videoLoader.validatePlayableVideo(at: url)
                try Task.checkCancellation()
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
                    self.reportRuntimeError(screenID, nil)
                    self.setupVideoPlayback(url: url, screen: liveScreen)
                }
            } catch is CancellationError {
                // Expected when the user superseded this transition before
                // `validatePlayableVideo` returned — no error to report.
                return
            } catch {
                let runtimeError = Self.runtimeError(from: error, url: url)
                let message = error.localizedDescription
                await MainActor.run { [weak self] in
                    guard let self,
                          self.transition.isCurrentTransition(generation, for: screenID) else { return }
                    self.reportRuntimeError(screenID, runtimeError)
                    Logger.error("Failed to setup video: \(message)", category: .screenManager)
                }
            }
        }
        transition.setValidationTask(task, for: screenID)
    }

    func applyConfiguration(_ configuration: ScreenConfiguration, to screen: Screen, preservingState: Bool = false) {
        do {
            guard let bookmarkData = configuration.videoBookmarkData else {
                throw NSError(domain: "ScreenManager", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "No saved video bookmark is available for this screen."
                ])
            }

            let resolved: SecurityScopedBookmarkResolver.Resolved
            switch SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient) {
            case .success(let value):
                resolved = value
            case .failure(let failure):
                throw NSError(domain: "ScreenManager", code: 404, userInfo: [
                    NSLocalizedDescriptionKey: failure.localizedDescription
                ])
            }

            let url = resolved.url
            let effectiveConfiguration: ScreenConfiguration
            if resolved.didRefresh {
                let updatedConfig = configuration.withUpdatedActiveBookmark(resolved.bookmarkData)
                save(updatedConfig)
                effectiveConfiguration = updatedConfig
            } else {
                effectiveConfiguration = configuration
            }

            guard url.startAccessingSecurityScopedResource() else {
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                    throw NSError(domain: "ScreenManager", code: 403, userInfo: [
                        NSLocalizedDescriptionKey: "Cannot access the video file. Permission denied."
                    ])
                }
                return applyConfigurationForAccessibleURL(
                    url,
                    configuration: effectiveConfiguration,
                    screen: screen,
                    preservingState: preservingState
                )
            }
            defer { url.stopAccessingSecurityScopedResource() }

            applyConfigurationForAccessibleURL(
                url,
                configuration: effectiveConfiguration,
                screen: screen,
                preservingState: preservingState
            )
        } catch let error as NSError {
            Logger.error("Failed to apply configuration: \(error.localizedDescription) [domain=\(error.domain) code=\(error.code)]", category: .screenManager)
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
        let needsNewPlayer = existingPlayer == nil ||
            Self.videoAudioURLKey(for: existingPlayer?.videoURL) != Self.videoAudioURLKey(for: url)

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

            player.setVolume(configuration.videoVolume)
            player.setMuted(configuration.muted)
            player.setVideoColorSpace(configuration.videoColorSpace)
            player.setPlaybackSpeed(configuration.playbackSpeed)
            applyConfigurationWhenAssetReady(player: player, screen: screen, configuration: configuration)
            applyStartupPlaybackPolicy(to: player, for: screen)
        }

        reportRuntimeError(screen.id, nil)
        syncVideoAudioLeadership()
        applyVideoSpanLayout()
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

        if let configuration {
            player.setVolume(configuration.videoVolume)
            player.setMuted(configuration.muted)
            player.setVideoColorSpace(configuration.videoColorSpace)
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

        syncVideoAudioLeadership()
        applyVideoSpanLayout()
        applyStartupPlaybackPolicy(to: player, for: liveScreen)
        Logger.info("Video player initialized for screen \(screen.id) — async asset load in progress", category: .screenManager)
        notifyWallpaperSessionChanged()
    }

    // MARK: - Helpers

    private func save(_ configuration: ScreenConfiguration) {
        configurationStore.save(configuration)
        let screenID = configuration.screenID
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .wallpaperConfigurationDidChange,
                object: nil,
                userInfo: ["screenID": screenID]
            )
        }
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

    private static func clampedVideoVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0), 1)
    }

    private func syncVideoAudioLeadership() {
        let screens = screensProvider()
        let entries = screens.compactMap { screen -> VideoAudioLeadershipPolicy.Entry? in
            guard let player = screen.videoPlayer,
                  let configuration = configurationStore.get(for: screen.id),
                  configuration.wallpaperType == .video else { return nil }
            return VideoAudioLeadershipPolicy.Entry(
                screenID: screen.id,
                urlKey: Self.videoAudioURLKey(for: player.videoURL),
                userMuted: configuration.muted
            )
        }
        let effectiveMutedStates = VideoAudioLeadershipPolicy.effectiveMutedStates(for: entries)

        for screen in screens {
            guard let player = screen.videoPlayer,
                  let configuration = configurationStore.get(for: screen.id),
                  configuration.wallpaperType == .video else { continue }
            player.setVolume(configuration.videoVolume)
            player.setMuted(effectiveMutedStates[screen.id] ?? configuration.muted)
        }
    }

    private func applyVideoSpanLayout() {
        let screens = screensProvider()
        let candidates = screens.compactMap { screen -> (screen: Screen, player: WallpaperVideoPlayer, urlKey: String)? in
            guard let player = screen.videoPlayer,
                  let configuration = configurationStore.get(for: screen.id),
                  configuration.wallpaperType == .video,
                  configuration.videoDisplayMode == .spanAllDisplays,
                  let urlKey = Self.videoAudioURLKey(for: player.videoURL) else {
                return nil
            }
            return (screen, player, urlKey)
        }

        let groups = Dictionary(grouping: candidates) { $0.urlKey }
        var spannedScreenIDs = Set<CGDirectDisplayID>()

        for group in groups.values where group.count > 1 {
            let renderConfigurations = VideoSpanLayout.renderConfigurations(
                for: group.map { item in
                    VideoSpanLayout.Entry(screenID: item.screen.id, frame: item.screen.frame)
                }
            )
            guard !renderConfigurations.isEmpty else { continue }

            synchronizeSpanGroupPlaybackTimes(group)

            for item in group {
                item.player.setSpanRenderConfiguration(renderConfigurations[item.screen.id])
                spannedScreenIDs.insert(item.screen.id)
            }
        }

        for screen in screens where !spannedScreenIDs.contains(screen.id) {
            screen.videoPlayer?.setSpanRenderConfiguration(nil)
        }
    }

    private func synchronizeSpanGroupPlaybackTimes(
        _ group: [(screen: Screen, player: WallpaperVideoPlayer, urlKey: String)]
    ) {
        guard group.count > 1,
              let leaderPlayer = group.first?.player.player else { return }

        let leaderTime = leaderPlayer.currentTime()
        guard leaderTime.isValid else { return }

        for item in group.dropFirst() {
            guard let followerPlayer = item.player.player else { continue }
            let delta = CMTimeGetSeconds(CMTimeSubtract(followerPlayer.currentTime(), leaderTime))
            guard delta.isFinite, abs(delta) > 0.20 else { continue }
            followerPlayer.seek(to: leaderTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private static func videoAudioURLKey(for url: URL?) -> String? {
        guard let url else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    private static func runtimeError(from error: Error, url: URL) -> WallpaperRuntimeError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorNotConnectedToInternet {
            return .networkOffline
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return .fileAccessDenied(url)
        }
        return .mediaNotPlayable(url, code: nsError.code)
    }

    private static func bookmarkResolves(to url: URL, bookmark: Data?) -> Bool {
        guard let bookmark else { return false }
        guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            bookmark,
            target: .transient
        ) else { return false }
        return videoAudioURLKey(for: resolved.url) == videoAudioURLKey(for: url)
    }
}
