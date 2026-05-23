import AppKit
import Foundation
import Testing
import WebKit
@testable import LiveWallpaper

/// Validates the surface that PlaybackCoordinator extraction is meant to
/// preserve: the per-screen transition registry plus the four configuration
/// setters that ScreenManager forwards through the coordinator. Pure
/// unit-level coverage; runtime-session heavy paths live in the dedicated
/// session-lifecycle suites.
@Suite("ScreenManager ↔ PlaybackCoordinator coordination")
@MainActor
struct ScreenManagerCoordinationTests {

    // MARK: - PlaybackTransitionRegistry

    @Test("bumpTransition starts at 1 and increments monotonically per screen")
    func bumpTransitionIncrementsMonotonically() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 100

        #expect(registry.bumpTransition(for: screenID) == 1)
        #expect(registry.bumpTransition(for: screenID) == 2)
        #expect(registry.bumpTransition(for: screenID) == 3)
    }

    @Test("Each screen ID has an independent generation counter")
    func transitionGenerationsAreIndependentPerScreen() {
        let registry = PlaybackTransitionRegistry()

        #expect(registry.bumpTransition(for: 100) == 1)
        #expect(registry.bumpTransition(for: 200) == 1)
        #expect(registry.bumpTransition(for: 100) == 2)
        #expect(registry.bumpTransition(for: 200) == 2)
    }

    @Test("isCurrentTransition rejects stale generations")
    func isCurrentTransitionRejectsStaleGenerations() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 300

        let stale = registry.bumpTransition(for: screenID)
        let current = registry.bumpTransition(for: screenID)

        #expect(registry.isCurrentTransition(current, for: screenID))
        #expect(!registry.isCurrentTransition(stale, for: screenID))
    }

    @Test("cancelAssetReadiness cancels the installed work")
    func cancelAssetReadinessCancelsInstalledWork() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 400
        let task = Self.makeSuspendedTask()
        defer { task.cancel() }

        registry.setAssetReadiness(Self.makeWork(task: task), for: screenID)
        registry.cancelAssetReadiness(for: screenID)

        #expect(task.isCancelled)
    }

    @Test("cancelAssetReadiness is harmless when no work is installed")
    func cancelAssetReadinessOnEmptySlotIsNoOp() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 401
        let task = Self.makeSuspendedTask()
        defer {
            task.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.cancelAssetReadiness(for: screenID)
        registry.setAssetReadiness(Self.makeWork(task: task), for: screenID)

        #expect(!task.isCancelled)
    }

    @Test("setAssetReadiness cancels prior work when replacing")
    func setAssetReadinessCancelsPriorWork() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 500
        let priorTask = Self.makeSuspendedTask()
        let replacementTask = Self.makeSuspendedTask()
        defer {
            priorTask.cancel()
            replacementTask.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.setAssetReadiness(Self.makeWork(task: priorTask), for: screenID)
        registry.setAssetReadiness(Self.makeWork(task: replacementTask), for: screenID)

        #expect(priorTask.isCancelled)
        #expect(!replacementTask.isCancelled)
    }

    @Test("clearAssetReadinessIfMatch removes the matching installed work")
    func clearAssetReadinessIfMatchRemovesMatchingWork() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 600
        let installedTask = Self.makeSuspendedTask()
        let installedWork = Self.makeWork(task: installedTask)
        let replacementTask = Self.makeSuspendedTask()
        defer {
            installedTask.cancel()
            replacementTask.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.setAssetReadiness(installedWork, for: screenID)
        registry.clearAssetReadinessIfMatch(installedWork, for: screenID)

        registry.setAssetReadiness(Self.makeWork(task: replacementTask), for: screenID)

        withExtendedLifetime(installedWork) {
            #expect(!installedTask.isCancelled)
        }
        #expect(!replacementTask.isCancelled)
    }

    @Test("clearAssetReadinessIfMatch is a no-op when a newer work has replaced the slot")
    func clearAssetReadinessIfMatchIgnoresStaleHandle() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 601
        let originalWork = AssetReadinessWork()
        let newerTask = Self.makeSuspendedTask()
        let newerWork = Self.makeWork(task: newerTask)
        defer {
            newerTask.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.setAssetReadiness(originalWork, for: screenID)
        registry.setAssetReadiness(newerWork, for: screenID)
        registry.clearAssetReadinessIfMatch(originalWork, for: screenID)

        let followupTask = Self.makeSuspendedTask()
        defer { followupTask.cancel() }
        registry.setAssetReadiness(Self.makeWork(task: followupTask), for: screenID)

        #expect(newerTask.isCancelled)
    }

    // MARK: - ScreenManager → PlaybackCoordinator setter forwarding

    @Test("updatePlaybackSpeed mutates configuration and posts a change notification")
    func updatePlaybackSpeedForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let target = Self.differentValue(
                from: manager.getConfiguration(for: screen)?.playbackSpeed,
                options: [0.5, 0.75, 1.0, 1.5]
            )
            try await Self.expectChange(notificationFor: screen) {
                manager.updatePlaybackSpeed(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.playbackSpeed == target)
        }
    }

    @Test("updateMuted mutates configuration and posts a change notification")
    func updateMutedForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let current = manager.getConfiguration(for: screen)?.muted ?? true
            let target = !current
            try await Self.expectChange(notificationFor: screen) {
                manager.updateMuted(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.muted == target)
        }
    }

    @Test("updateVideoVolume mutates configuration and posts a change notification")
    func updateVideoVolumeForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let target = 0.42
            try await Self.expectChange(notificationFor: screen) {
                manager.updateVideoVolume(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.videoVolume == target)
        }
    }

    @Test("updateFitMode mutates configuration and posts a change notification")
    func updateFitModeForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let current = manager.getConfiguration(for: screen)?.fitMode ?? .aspectFill
            let target: VideoFitMode = current == .aspectFill ? .aspectFit : .aspectFill
            try await Self.expectChange(notificationFor: screen) {
                manager.updateFitMode(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.fitMode == target)
        }
    }

    @Test("updateFrameRateLimit mutates configuration and posts a change notification")
    func updateFrameRateLimitForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let current = manager.getConfiguration(for: screen)?.frameRateLimit ?? .fps60
            let target: FrameRateLimit = current == .fps60 ? .fps30 : .fps60
            try await Self.expectChange(notificationFor: screen) {
                manager.updateFrameRateLimit(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.frameRateLimit == target)
        }
    }

    @Test("Re-applying the current playback speed is a no-op (no notification)")
    func updatePlaybackSpeedWithSameValueIsNoOp() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            guard let currentSpeed = manager.getConfiguration(for: screen)?.playbackSpeed else {
                Issue.record("Seeded configuration is missing playbackSpeed")
                return
            }
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.updatePlaybackSpeed(currentSpeed, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.playbackSpeed == currentSpeed)
        }
    }

    @Test("Re-applying the current effect config is a no-op (no notification)")
    func updateEffectConfigWithSameValueIsNoOp() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let currentConfig = try #require(manager.getConfiguration(for: screen)?.effectConfig)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.updateEffectConfig(currentConfig, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.effectConfig == currentConfig)
        }
    }

    @Test("Re-applying the current particle effect is a no-op (no notification)")
    func updateParticleEffectWithSameValueIsNoOp() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let currentEffect = try #require(manager.getConfiguration(for: screen)?.particleEffect)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.updateParticleEffect(currentEffect, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.particleEffect == currentEffect)
        }
    }

    @Test("Re-applying the current weather-reactive setting is a no-op (no notification)")
    func setWeatherReactiveWithSameValueIsNoOp() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let currentValue = try #require(manager.getConfiguration(for: screen)?.effectConfig.weatherReactive as Bool?)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.setWeatherReactive(currentValue, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.effectConfig.weatherReactive == currentValue)
        }
    }

    // MARK: - Wallpaper type lifecycle regressions

    @Test("Switching to video without a saved video leaves the active HTML session intact")
    func switchToVideoWithoutSavedVideoIsNonDestructive() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.switchToVideoWallpaper(for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .html)
            #expect(capture.notifications.isEmpty)
        }
    }

    @Test("Updating video mode without a saved video leaves the active HTML session intact")
    func updateWallpaperModeWithoutSavedVideoIsIgnored() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.updateWallpaperMode(.playlist, for: screen)
            await Self.drainMainQueue()

            let config = try #require(manager.getConfiguration(for: screen))
            #expect(config.wallpaperType == .html)
            #expect(config.wallpaperMode == .playlist)
            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(capture.notifications.isEmpty)
        }
    }

    @Test("Switching to video while the same video wallpaper is already active keeps the live session")
    func switchToVideoWhenAlreadyActiveKeepsSession() async throws {
        let fixture = try Self.makeTemporaryVideoBookmark(prefix: "switch-video")
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try await Self.runWithVideoConfiguration(bookmarkData: fixture.bookmark) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .video)
            screen.installRuntimeSession(session)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.switchToVideoWallpaper(for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .video)
        }
    }

    @Test("Re-applying the same scene wallpaper keeps the live session")
    func setSameSceneWallpaperKeepsSession() async throws {
        let descriptor = Self.makeSceneDescriptor()

        try await Self.runWithSceneConfiguration(descriptor: descriptor) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .scene)
            screen.installRuntimeSession(session)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.setSceneWallpaper(descriptor: descriptor, origin: nil, for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .scene)
        }
    }

    @Test("Applying a different scene descriptor replaces the live session")
    func setDifferentSceneWallpaperReplacesSession() async throws {
        let original = Self.makeSceneDescriptor()
        let replacement = Self.makeSceneDescriptor()

        try await Self.runWithSceneConfiguration(descriptor: original) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .scene)
            screen.installRuntimeSession(session)

            manager.setSceneWallpaper(descriptor: replacement, origin: nil, for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 1)
            #expect(!Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.activeWallpaper == .scene(replacement))
        }
    }

    @Test("Applying a different video bookmark replaces the live player")
    func applyDifferentVideoConfigurationReplacesLivePlayer() async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for video replacement test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        let first = try Self.makeTemporaryVideoBookmark(prefix: "old-video")
        let second = try Self.makeTemporaryVideoBookmark(prefix: "new-video")
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
            screen.resetRuntimeSession()
        }

        let configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: second.bookmark)
        SettingsManager.shared.replaceAllConfigurations([configuration])
        let store = WallpaperConfigurationStore()
        _ = store.loadAll()

        let oldPlayer = WallpaperVideoPlayer(url: first.url, frame: screen.frame)
        screen.installRuntimeSession(VideoWallpaperSession(player: oldPlayer))

        var releaseCount = 0
        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            powerPolicy: PowerPolicyController(),
            playableVideoLoader: FakePlayableVideoLoader(),
            applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 },
            screensProvider: { [screen] },
            markSessionStateChanged: {},
            releaseRuntimeSession: { target in
                releaseCount += 1
                target.resetRuntimeSession()
            },
            notifyWallpaperSessionChanged: {},
            originReconciler: PreservingOriginReconciler()
        )
        defer { coordinator.transition.cancelAssetReadiness(for: screen.id) }

        coordinator.applyConfiguration(configuration, to: screen, preservingState: false)

        let currentPlayer = try #require(screen.videoPlayer)
        #expect(releaseCount == 1)
        #expect(currentPlayer !== oldPlayer)
        #expect(Self.canonicalFilePath(currentPlayer.videoURL) == Self.canonicalFilePath(second.url))
    }

    @Test("Applying a config to the existing video player syncs audio settings")
    func applyConfigurationSyncsAudioSettingsToExistingPlayer() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for PlaybackCoordinator audio sync test")
            return
        }

        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        let fixture = try Self.makeTemporaryVideoBookmark(prefix: "audio-sync")
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: fixture.bookmark)
        configuration.muted = true
        configuration.videoVolume = 0.35
        SettingsManager.shared.replaceAllConfigurations([configuration])
        let store = WallpaperConfigurationStore()
        _ = store.loadAll()

        let player = WallpaperVideoPlayer(url: fixture.url, frame: screen.frame, loadImmediately: false)
        player.setMuted(false)
        player.setVolume(0.9)
        screen.installRuntimeSession(VideoWallpaperSession(player: player))
        defer { screen.resetRuntimeSession() }

        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            powerPolicy: PowerPolicyController(),
            playableVideoLoader: FakePlayableVideoLoader(),
            applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 },
            screensProvider: { [screen] },
            markSessionStateChanged: {},
            releaseRuntimeSession: { target in target.resetRuntimeSession() },
            notifyWallpaperSessionChanged: {},
            originReconciler: PreservingOriginReconciler()
        )
        defer { coordinator.transition.cancelAssetReadiness(for: screen.id) }

        coordinator.applyConfiguration(configuration, to: screen, preservingState: true)

        let currentPlayer = try #require(screen.videoPlayer)
        #expect(currentPlayer === player)
        #expect(currentPlayer.isMuted)
        #expect(currentPlayer.audioVolume == 0.35)
    }

    @Test("Duplicate video audio leadership keeps only the first unmuted screen audible")
    func duplicateVideoAudioLeadershipKeepsSingleAudibleScreen() {
        let entries = [
            VideoAudioLeadershipPolicy.Entry(screenID: 1, urlKey: "/wallpapers/shared.mp4", userMuted: false),
            VideoAudioLeadershipPolicy.Entry(screenID: 2, urlKey: "/wallpapers/shared.mp4", userMuted: false),
            VideoAudioLeadershipPolicy.Entry(screenID: 3, urlKey: "/wallpapers/other.mp4", userMuted: false),
            VideoAudioLeadershipPolicy.Entry(screenID: 4, urlKey: "/wallpapers/shared.mp4", userMuted: true)
        ]

        let effective = VideoAudioLeadershipPolicy.effectiveMutedStates(for: entries)

        #expect(effective[1] == false)
        #expect(effective[2] == true)
        #expect(effective[3] == false)
        #expect(effective[4] == true)
    }

    @Test("Video validation failure is surfaced as a runtime error for the screen")
    func setVideoValidationFailureSurfacesRuntimeError() async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for video validation error test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        let fixture = try Self.makeTemporaryVideoBookmark(prefix: "validation-error")
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            screen.resetRuntimeSession()
        }

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(validationError: .validationFailed),
            displayRegistry: FakeDisplayRegistry(screens: [screen])
        ))

        manager.setVideo(url: fixture.url, bookmarkData: fixture.bookmark, for: screen)

        for _ in 0..<20 where manager.runtimeError(for: screen) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        let error = try #require(manager.runtimeError(for: screen))
        guard case .mediaNotPlayable(let url, _) = error else {
            Issue.record("Expected mediaNotPlayable, got \(error)")
            return
        }
        #expect(url == fixture.url)
    }

    @Test("Updating live HTML config hot-applies ordinary toggles without rebuilding the session")
    func updateHTMLConfigHotAppliesWithoutRebuild() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            var updated = HTMLConfig.default
            updated.allowMouseInteraction = true
            updated.customCSS = "html { background: black; }"

            try await Self.expectChange(notificationFor: screen) {
                manager.updateHTMLConfig(updated, for: screen)
            }

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(session.appliedHTMLConfigs == [updated])
            #expect(manager.getConfiguration(for: screen)?.htmlConfig == updated)
        }
    }

    @Test("Updating Wallpaper Engine project property overrides hot-applies without rebuilding the session")
    func updateHTMLConfigProjectPropertiesHotAppliesWithoutRebuild() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            var updated = HTMLConfig.default
            updated.wallpaperEngineProjectProperties = [
                "mouseactions": .bool(true),
                "bgmvolume": .number(35),
                "modelresolution": .string("4k")
            ]

            try await Self.expectChange(notificationFor: screen) {
                manager.updateHTMLConfig(updated, for: screen)
            }

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(session.appliedHTMLConfigs == [updated])
            #expect(manager.getConfiguration(for: screen)?.htmlConfig == updated)
        }
    }

    @Test("Switching to HTML while the same HTML wallpaper is already active keeps the live session")
    func switchToHTMLWhenAlreadyActiveKeepsSession() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.switchToHTMLWallpaper(for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .html)
        }
    }

    @Test("Re-applying the current HTML config is a no-op (no notification)")
    func updateHTMLConfigWithSameValueIsNoOp() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)
            let currentConfig = try #require(manager.getConfiguration(for: screen)?.htmlConfig)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.updateHTMLConfig(currentConfig, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(session.cleanupCount == 0)
            #expect(session.appliedHTMLConfigs.isEmpty)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.htmlConfig == currentConfig)
        }
    }

    @Test("Trusting the current remote HTML origin forces the live page to rebuild")
    func trustingCurrentRemoteHTMLOriginForcesRebuild() async throws {
        let originURL = try #require(URL(string: "https://html-refresh-\(UUID().uuidString).example.com/live"))
        let source = HTMLSource.url(originURL)
        let origin = try #require(TrustedHTMLOrigin(url: originURL))
        var config = HTMLConfig.default
        config.allowJavaScript = true

        try await Self.runWithHTMLConfiguration(source: source, config: config) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)
            defer { _ = TrustedHostStore.shared.revoke(origin) }

            #expect(TrustedHostStore.shared.trust(origin))
            manager.setHTMLWallpaper(source: source, config: config, forceReload: true, for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 1)
            #expect(!Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .html)
        }
    }

    @Test("Revoking the current trusted HTML origin forces the live page to rebuild")
    func revokingCurrentTrustedHTMLOriginForcesRebuild() async throws {
        let originURL = try #require(URL(string: "https://html-revoke-\(UUID().uuidString).example.com/live"))
        let source = HTMLSource.url(originURL)
        let origin = try #require(TrustedHTMLOrigin(url: originURL))
        var config = HTMLConfig.default
        config.allowJavaScript = true

        #expect(TrustedHostStore.shared.trust(origin))
        defer { _ = TrustedHostStore.shared.revoke(origin) }

        try await Self.runWithHTMLConfiguration(source: source, config: config) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            #expect(TrustedHostStore.shared.revoke(origin))
            manager.setHTMLWallpaper(source: source, config: config, forceReload: true, for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 1)
            #expect(!Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .html)
        }
    }

    @Test("Changing HTML JavaScript permission rebuilds the page")
    func updateHTMLConfigJavaScriptToggleRebuildsSession() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            var updated = HTMLConfig.default
            updated.allowJavaScript = false

            try await Self.expectChange(notificationFor: screen) {
                manager.updateHTMLConfig(updated, for: screen)
            }

            #expect(session.cleanupCount == 1)
            #expect(!Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.htmlConfig == updated)
        }
    }

    @Test("Changing HTML tracker blocking rebuilds the page")
    func updateHTMLConfigTrackerBlockingToggleRebuildsSession() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            var updated = HTMLConfig.default
            updated.blockTrackers = false

            try await Self.expectChange(notificationFor: screen) {
                manager.updateHTMLConfig(updated, for: screen)
            }

            #expect(session.cleanupCount == 1)
            #expect(!Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.htmlConfig == updated)
        }
    }

    @Test("Cancelled HTML navigations do not surface as runtime errors")
    func cancelledHTMLNavigationIsIgnored() {
        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        defer { view.cleanup() }

        var errors: [WallpaperRuntimeError] = []
        view.onError = { errors.append($0) }

        view.webView(
            WKWebView(frame: .zero),
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )

        #expect(errors.isEmpty)
    }

    @Test("Late HTML navigation failures after cleanup do not surface as runtime errors")
    func lateHTMLNavigationFailureAfterCleanupIsIgnored() {
        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))

        var errors: [WallpaperRuntimeError] = []
        view.onError = { errors.append($0) }
        view.cleanup()

        view.webView(
            WKWebView(frame: .zero),
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        )

        #expect(errors.isEmpty)
    }

    // MARK: - Helpers

    private static func makeSuspendedTask() -> Task<Void, Never> {
        Task.detached {
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private static func makeWork(task: Task<Void, Never>) -> AssetReadinessWork {
        let work = AssetReadinessWork()
        work.fallbackTask = task
        return work
    }

    private static func differentValue<T: Equatable>(from current: T?, options: [T]) -> T {
        precondition(!options.isEmpty, "differentValue requires a non-empty option set")
        if let current, let next = options.first(where: { $0 != current }) {
            return next
        }
        return options[0]
    }

    private static func canonicalFilePath(_ url: URL?) -> String? {
        url?.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    /// Boots a `ScreenManager` with the four protocol fakes, ensures a `ScreenConfiguration` exists for the host's primary screen, and runs the closure.
    private static func runWithSeededConfiguration(
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager coordination test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        if !originalConfigurations.contains(where: { $0.screenID == screen.id }) {
            SettingsManager.shared.saveConfiguration(
                ScreenConfiguration(screenID: screen.id, wallpaper: .metalShader(.waves))
            )
        }

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen])
        ))

        guard manager.getConfiguration(for: screen) != nil else {
            Issue.record("Could not seed a ScreenConfiguration for the host screen")
            return
        }

        try await body(manager, screen)
    }

    private static func runWithHTMLConfiguration(
        source: HTMLSource = .inline("<html><body></body></html>"),
        config: HTMLConfig = .default,
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager coordination test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(
                screenID: screen.id,
                wallpaper: .html(source: source, config: config),
                savedVideoBookmarkData: nil
            )
        ])

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen])
        ))

        defer { screen.resetRuntimeSession() }
        try await body(manager, screen)
    }

    private static func runWithVideoConfiguration(
        bookmarkData: Data,
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager coordination test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: screen.id, videoBookmarkData: bookmarkData)
        ])

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen])
        ))

        defer { screen.resetRuntimeSession() }
        try await body(manager, screen)
    }

    private static func runWithSceneConfiguration(
        descriptor: SceneDescriptor,
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager coordination test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor))
        ])

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen])
        ))

        defer { screen.resetRuntimeSession() }
        try await body(manager, screen)
    }

    private static func makeTemporaryVideoBookmark(prefix: String) throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-\(prefix)-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01]).write(to: url)
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return (url, bookmark)
    }

    private static func makeSceneDescriptor() -> SceneDescriptor {
        SceneDescriptor(
            workshopID: "scene-refresh-\(UUID().uuidString)",
            cacheRelativePath: "wpe-cache/scene-refresh",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
    }

    private static func isSameSession(
        _ lhs: (any WallpaperRuntimeSession)?,
        _ rhs: TestRuntimeSession
    ) -> Bool {
        guard let lhs else { return false }
        return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs)
    }

    /// Snapshots notifications observed during `mutation`, asserting exactly one new `.wallpaperConfigurationDidChange` for the given screen.
    private static func expectChange(
        notificationFor screen: Screen,
        _ mutation: () -> Void
    ) async throws {
        let capture = attachConfigurationObserver()
        defer { capture.detach() }

        mutation()
        try await capture.waitForNotifications(count: 1, timeout: .milliseconds(500))

        #expect(capture.notifications.count == 1)
        #expect(capture.notifications.first?.screenID == screen.id)
    }

    private static func attachConfigurationObserver() -> ConfigurationNotificationCapture {
        ConfigurationNotificationCapture(name: .wallpaperConfigurationDidChange)
    }

    private static func drainMainQueue() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        await Task.yield()
    }
}

/// Captures notifications synchronously on the posting thread. The
/// PlaybackCoordinator's setters run on `@MainActor`, so posts arrive on the
/// main thread; using a `nil` operation queue keeps the observer on that same
/// thread and sidesteps Swift 6 cross-isolation `@Sendable` requirements on
/// `Notification`.
private final class ConfigurationNotificationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScreenChangeRecord] = []
    private var observer: NSObjectProtocol?

    init(name: Notification.Name) {
        observer = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let record = ScreenChangeRecord(
                screenID: ConfigurationNotificationCapture.screenID(from: notification)
            )
            self?.append(record)
        }
    }

    deinit {
        detach()
    }

    var notifications: [ScreenChangeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func detach() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    func waitForNotifications(count: Int, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if notifications.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func append(_ record: ScreenChangeRecord) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(record)
    }

    private static func screenID(from notification: Notification) -> CGDirectDisplayID? {
        let raw = notification.userInfo?["screenID"]
        if let direct = raw as? CGDirectDisplayID { return direct }
        if let number = raw as? NSNumber { return CGDirectDisplayID(number.uint32Value) }
        return nil
    }
}

private struct ScreenChangeRecord: Sendable {
    let screenID: CGDirectDisplayID?
}

@MainActor
private final class TestRuntimeSession: WallpaperRuntimeSession, HTMLWallpaperConfigApplying {
    let wallpaperType: WallpaperType
    private(set) var cleanupCount = 0
    private(set) var appliedHTMLConfigs: [HTMLConfig] = []

    init(wallpaperType: WallpaperType) {
        self.wallpaperType = wallpaperType
    }

    var summary: WallpaperSessionSummary {
        WallpaperSessionSummary(
            wallpaperType: wallpaperType,
            activity: .active,
            supportsPlaybackControl: false,
            subtitle: nil
        )
    }

    var videoPlayer: WallpaperVideoPlayer? { nil }
    var wallpaperWindow: NSWindow? { nil }

    func show() {}
    func hide() {}
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {}
    func updateFrame(to frame: CGRect) {}
    func cleanup() { cleanupCount += 1 }

    func applyHTMLConfig(_ config: HTMLConfig) -> Bool {
        appliedHTMLConfigs.append(config)
        return true
    }
}
