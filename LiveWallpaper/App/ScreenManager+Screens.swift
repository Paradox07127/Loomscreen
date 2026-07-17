import SwiftUI
import Combine
import LiveWallpaperCore
import Observation

extension ScreenManager {
    func refreshScreens(preserveRuntimeSessions: Bool = true) {
        guard !isTerminating else { return }
        let newScreens = displayRegistry.currentScreens()
        Logger.screensDetected(newScreens.count)

        let oldScreens = screens
        let oldScreenIDs = Set(oldScreens.map(\.id))
        let newScreenIDs = Set(newScreens.map(\.id))
        let oldFingerprintsByID = Dictionary(
            oldScreens.map { ($0.id, $0.displayFingerprint) },
            uniquingKeysWith: { first, _ in first }
        )

        for screenID in oldScreenIDs.subtracting(newScreenIDs) {
            if let screen = oldScreens.first(where: { $0.id == screenID }) {
                Logger.info("Cleaning up removed screen \(screenID)", category: .screenManager)
                releaseRuntimeSession(screen)
            }

        }

        // A recycled/repurposed CGDirectDisplayID (same ID, different physical
        // panel) reports a new displayFingerprint. That is an identity change:
        // adopting the prior panel's session by ID alone would inherit the wrong
        // wallpaper and bypass the fingerprint-aware config lookup, so treat it
        // like a fresh display — release the stale session and reload below.
        let identityChangedIDs = Set(newScreens.compactMap { newScreen -> CGDirectDisplayID? in
            guard let oldFingerprint = oldFingerprintsByID[newScreen.id],
                  oldFingerprint != newScreen.displayFingerprint else { return nil }
            return newScreen.id
        })
        for screen in oldScreens where identityChangedIDs.contains(screen.id) {
            Logger.info("Display \(screen.id) fingerprint changed — releasing prior panel's session", category: .screenManager)
            releaseRuntimeSession(screen)
        }

        if !preserveRuntimeSessions {
            for screen in oldScreens where newScreenIDs.contains(screen.id) {
                releaseRuntimeSession(screen)
            }
        }

        var updatedScreens = [Screen]()

        for newScreen in newScreens {
            if preserveRuntimeSessions,
               !identityChangedIDs.contains(newScreen.id),
               let existingScreen = oldScreens.first(where: { $0.id == newScreen.id }) {
                newScreen.adoptRuntimeSession(from: existingScreen)
            }

            updatedScreens.append(newScreen)
        }

        screens = updatedScreens

        let reloadIDs = newScreenIDs.subtracting(oldScreenIDs).union(identityChangedIDs)
        for screen in newScreens where reloadIDs.contains(screen.id) {
            Logger.info("Configuring new screen \(screen.id)", category: .screenManager)
            if restoresSavedWallpapersOnScreenRefresh {
                loadConfigurationForScreen(screen)
            }
        }

        updateAllWindowFrames()

        refreshWallpaperSessionSummaryCache()
        updatePlaybackState()
        updateFullScreenFallbackPolling()

        // Enforce a persisted "off" master gate. With the build gate in
        // `restoreWallpaperSession`, disabled screens never build a session
        // above; this is the safety net that also tears down any session
        // adopted/preserved across a screen refresh so nothing stays resident.
        if !wallpapersGloballyEnabled {
            applyGlobalRenderGate()
        }

        NotificationCenter.default.post(name: .screensRefreshed, object: nil)
    }

    func clearWallpaperForScreen(_ screen: Screen) {
        Logger.info("Clearing wallpaper for screen \(screen.id)", category: .screenManager)
        releaseRuntimeSession(screen)
        persistence.remove(for: screen.id)
        notifyWallpaperSessionChanged()
    }

    /// Clear only one wallpaper type for this screen — drops that type's saved
    /// state (saved video bookmark, saved HTML source, etc.). If the
    /// currently-active wallpaper is the type being cleared, falls back to
    /// the next saved type (video → html) so the screen doesn't blank out
    /// while the user still has a usable picks from another tab; only when
    /// no fallback exists does this collapse to a full `clearWallpaperForScreen`.
    func clearWallpaperOfType(_ type: WallpaperType, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }

        let wasActive = (config.activeWallpaper.wallpaperType == type)
        // Switching away from an active scene drops its origin metadata too, so a
        // later reload can't re-resolve a deleted scene from a stale `wpeOrigin`.
        if wasActive, type == .scene {
            config.wpeOrigin = nil
        }

        switch type {
        case .video:
            config.savedVideoBookmarkData = nil
            config.playlistBookmarks = nil
            config.playlistPrimaryIndex = nil
        case .html:
            config.savedHTMLSource = nil
            config.savedHTMLConfig = nil
        case .scene:
            config.savedSceneDescriptor = nil
        case .monitor:
            config.savedMonitorConfiguration = nil
        case .metalShader:
            break
        }

        guard wasActive else {
            saveConfiguration(config)
            return
        }

        if type != .video, config.activateSavedVideoWallpaper() {
            saveConfiguration(config)
            restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
            return
        }

        if type != .html, config.activateSavedHTMLWallpaper() {
            saveConfiguration(config)
            restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
            return
        }

        clearWallpaperForScreen(screen)
    }

    /// Tears down the live runtime session without touching persistence.
    func releaseRuntimeSession(_ screen: Screen) {
        adaptiveFrameRateOcclusionThrottled[screen.id] = nil
        suspendedScreenIDs.remove(screen.id)
        bumpTransition(for: screen.id)
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.cancelInflight(for: screen.id)
        }
        transitionRegistry.cancelAssetReadiness(for: screen.id)
        setTransientRuntimeError(nil, for: screen.id)
        screen.resetRuntimeSession()
        playbackCoordinator.refreshVideoAudioLeadership()
        // A torn-down HTML leader must hand audio to a surviving same-source
        // follower; the session is already reset above so it is excluded here.
        htmlCoordinator.refreshAudioLeadership()
        refreshAppNapAssertion()
    }

    /// App-termination teardown: synchronously tears down every render session
    /// (each `cleanup()` pauses its AVPlayer, releases its WKWebView / Metal
    /// renderer, and closes its window) and stops lifecycle observers. Bounded — just
    /// a loop of in-process releases, no I/O — so it stays inside the terminate
    /// watchdog. Unlike `resetAllWallpaperSessions()` it skips config-cache
    /// clearing and async UI notifications, which are pointless mid-exit.
    func tearDownForTermination() {
        guard !isTerminating else { return }

        // The board debounces drag/resize edits. Flush that last user change
        // while persistence is still admitted; this method is MainActor and
        // does not suspend, so no other producer can enter before the latch is
        // closed immediately below.
        MonitorOverlayController.shared.teardownAll()
        isTerminating = true
        memoryPressureWatcher.stop()

        // Close every producer of future ScreenManager work before releasing
        // the current sessions. This invalidates queued Combine/Observation
        // callbacks and the 60-second automation loop; in-flight video
        // validations are invalidated below by each screen's transition bump.
        cleanupTasks.removeAll()
        fullScreenTrackingGeneration &+= 1
        fullScreenDetector.setFallbackPollingEnabled(false)
        fullScreenDetector.stop()
        automationOrchestrator.stopMonitoring()
        #if !LITE_BUILD
        wpeImportTracker.invalidateForTermination()
        #endif
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.shutdown()
        }
        if featureCatalog.isEnabled(.lockScreenSnapshots) {
            lockScreenSnapshotCoordinator.stop()
        }

        // The HUD owns a MonitorRuntime lease independently of wallpaper
        // sessions. The terminating latch also makes any overlay reconcile task
        // already queued for the next runloop a no-op.
        MonitorHUDController.shared.shutdown()

        for screen in screens {
            releaseRuntimeSession(screen)
        }
    }

    func resetAllWallpaperSessions() {
        let snapshot = screens
        for screen in snapshot {
            releaseRuntimeSession(screen)
        }
        configurationStore.clearCache()
        Task { @MainActor in
            for screen in snapshot {
                NotificationCenter.default.post(
                    name: .wallpaperConfigurationDidChange,
                    object: nil,
                    userInfo: ["screenID": screen.id]
                )
            }
        }
        notifyWallpaperSessionChanged()
    }
    

    /// Light launch-time pass: prunes configurations whose local resource bookmark is no longer resolvable.
    func pruneInvalidConfigurationsIfNeeded() {
        guard !isTerminating else { return }
        persistence.pruneInvalidConfigurations()
    }

    func loadConfigurationForScreen(_ screen: Screen) {
        guard !isTerminating else { return }
        if screen.videoPlayer != nil {
            if let cachedConfig = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) {
                primeBookmarkDisplayNames(from: cachedConfig)
                applyConfiguration(cachedConfig, to: screen, preservingState: true)
            }
            return
        }

        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        primeBookmarkDisplayNames(from: config)
        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
    }

    func restoreWallpaperSession(
        for screen: Screen,
        configuration: ScreenConfiguration,
        preservingState: Bool
    ) {
        guard !isTerminating else { return }
        // Master gate: when wallpapers are globally disabled we keep the
        // configuration persisted but do NOT build a live session. This avoids
        // allocating the renderer / scene runtime / decoded assets only to
        // suspend them — the session is (re)built by `applyGlobalRenderGate()`
        // when the master switch is turned back on.
        guard wallpapersGloballyEnabled else {
            if screen.runtimeSession != nil { releaseRuntimeSession(screen) }
            // No live session is built, but the caller has just persisted this
            // configuration. Refresh the derived session state so a wallpaper
            // assigned while the gate is off is reflected as configured-but-
            // `.off` (keeping the master switch enabled) — mirrors the video
            // path's refresh in `PlaybackCoordinator.setupVideoPlayback`.
            notifyWallpaperSessionChanged()
            return
        }

        guard let definition = WallpaperSessionDefinition(configuration: configuration) else {
            Logger.warning("Skipping malformed wallpaper configuration for screen \(screen.id)", category: .screenManager)
            releaseRuntimeSession(screen)
            return
        }

        switch definition {
        case .video:
            applyConfiguration(configuration, to: screen, preservingState: preservingState)
        case .html(let source, let htmlConfig):
            activateAmbientWallpaper(.html(source, htmlConfig), for: screen, configuration: configuration)
        case .metalShader(let shaderSource):
            activateAmbientWallpaper(.metalShader(shaderSource), for: screen, configuration: configuration)
        case .scene(let descriptor):
            activateAmbientWallpaper(.scene(descriptor), for: screen, configuration: configuration)
        case .monitor(let monitorConfig):
            activateAmbientWallpaper(.monitor(monitorConfig), for: screen, configuration: configuration)
        }
    }


    func saveConfiguration(_ configuration: ScreenConfiguration) {
        guard !isTerminating else { return }
        persistence.save(configuration)
    }

    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updatePlaybackSpeed(speed, for: screen)
    }

    func updateMuted(_ muted: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateMuted(muted, for: screen)
    }

    func updateVideoVolume(_ volume: Double, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateVideoVolume(volume, for: screen)
    }

    func updateVideoColorSpace(_ colorSpace: VideoColorSpace, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateVideoColorSpace(colorSpace, for: screen)
    }

    func updateSceneMouseInteraction(_ enabled: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateSceneMouseInteraction(enabled, for: screen)
    }

    func updateSceneClickCapture(_ enabled: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateSceneClickCapture(enabled, for: screen)
    }

    func updateVideoDisplayMode(_ mode: VideoDisplayMode, for screen: Screen) {
        guard !isTerminating else { return }
        guard var sourceConfiguration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              sourceConfiguration.wallpaperType == .video,
              sourceConfiguration.hasConfiguredVideoSource else { return }

        switch mode {
        case .perDisplay:
            let sourceBookmark = sourceConfiguration.videoBookmarkData
            var changed = false

            for target in screens {
                guard var targetConfiguration = configurationStore.get(for: target.id, fingerprint: target.displayFingerprint),
                      targetConfiguration.wallpaperType == .video,
                      targetConfiguration.videoDisplayMode == .spanAllDisplays else { continue }

                if let sourceBookmark,
                   targetConfiguration.videoBookmarkData != sourceBookmark {
                    continue
                }

                targetConfiguration.videoDisplayMode = .perDisplay
                saveConfiguration(targetConfiguration)
                restoreWallpaperSession(for: target, configuration: targetConfiguration, preservingState: true)
                changed = true
            }

            if changed {
                notifyWallpaperSessionChanged()
            } else {
                playbackCoordinator.updateVideoDisplayMode(mode, for: screen)
            }

        case .spanAllDisplays:
            guard screens.count > 1 else {
                playbackCoordinator.updateVideoDisplayMode(.perDisplay, for: screen)
                return
            }

            sourceConfiguration.videoDisplayMode = .spanAllDisplays
            for target in screens {
                var copy = sourceConfiguration
                copy.screenID = target.id
                copy.displayFingerprint = target.displayFingerprint

                if target.id != screen.id {
                    releaseRuntimeSession(target)
                }

                saveConfiguration(copy)
                restoreWallpaperSession(
                    for: target,
                    configuration: copy,
                    preservingState: target.id == screen.id
                )
                Logger.info("Span Video: copied configuration from screen \(screen.id) → \(target.id)", category: .screenManager)
            }
            notifyWallpaperSessionChanged()
        }
    }

    func updateFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateFitMode(fitMode, for: screen)
    }

    func updateSceneFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateSceneFitMode(fitMode, for: screen)
    }

    func updateFrameRateLimit(_ frameRateLimit: FrameRateLimit, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateFrameRateLimit(frameRateLimit, for: screen)
    }

    func applyFrameRateLimit(_ frameRateLimit: FrameRateLimit, to screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.applyFrameRateLimit(frameRateLimit, to: screen)
    }
    
    func getConfiguration(for screen: Screen) -> ScreenConfiguration? {
        configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)
    }

    func displayPlaybackDiffersFromDefaults(for screen: Screen) -> Bool {
        guard let config = getConfiguration(for: screen) else { return false }
        return config.playbackDiffers(from: SettingsManager.shared.loadDisplayDefaults())
    }

    func displaySettingsDifferFromDefaults(for screen: Screen) -> Bool {
        guard let config = getConfiguration(for: screen) else { return false }
        if config.storedPlaybackDiffers(from: SettingsManager.shared.loadDisplayDefaults()) {
            return true
        }
        return config.particleEffect != .none
            || config.effectConfig != .default
            || config.scheduleSlots != nil
            || config.shufflePlaylist
            || config.playlistRotationMinutes != nil
            || config.setAsLockScreen
            || config.wallpaperMode != .playlist
    }

    func resetPlaybackSettings(for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        config.resetPlayback(to: SettingsManager.shared.loadDisplayDefaults())
        saveConfiguration(config)
        restoreWallpaperSession(for: screen, configuration: config, preservingState: true)
        notifyWallpaperSessionChanged()
        Logger.info("Reset playback defaults for screen \(screen.id)", category: .screenManager)
    }

    /// Restores per-display playback / effect / audio / layout settings to
    /// their defaults while preserving the wallpaper content itself: video
    /// bookmarks, HTML source, scene/WPE source, playlist bookmarks, and
    /// WPE origin metadata are left intact. The HTML config that travels
    /// with `activeWallpaper` and `savedHTMLConfig` is reset to defaults
    /// since it represents settings, not source content.
    func resetDisplaySettings(for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }

        let displayDefaults = SettingsManager.shared.loadDisplayDefaults()
        config.resetStoredPlayback(to: displayDefaults)
        config.particleEffect = .none
        config.effectConfig = .default
        config.scheduleSlots = nil
        config.shufflePlaylist = false
        config.playlistRotationMinutes = nil
        config.setAsLockScreen = false
        config.wallpaperMode = .playlist
        config.savedHTMLConfig = .default
        config.resetSavedHTMLPlayback(to: displayDefaults, createIfMissing: true)
        if case .html(let source, _) = config.activeWallpaper {
            config.activeWallpaper = .html(source: source, config: .default)
            config.resetPlayback(to: displayDefaults)
        }

        releaseRuntimeSession(screen)
        saveConfiguration(config)
        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
        notifyWallpaperSessionChanged()
        Logger.info("Reset display settings for screen \(screen.id)", category: .screenManager)
    }

    /// Copies the active wallpaper + per-screen settings from `source` onto every other registered screen, restoring each runtime session so the new content shows immediately.
    func applyConfigurationToAllDisplays(from source: Screen) {
        guard !isTerminating,
              screens.count > 1,
              let template = configurationStore.get(for: source.id, fingerprint: source.displayFingerprint) else { return }

        for target in screens where target.id != source.id {
            var copy = template
            copy.screenID = target.id
            // Re-stamp with the TARGET's fingerprint; keeping the source's would
            // make this row unreachable by fingerprint after a display-ID reshuffle.
            copy.displayFingerprint = target.displayFingerprint
            releaseRuntimeSession(target)
            saveConfiguration(copy)
            restoreWallpaperSession(for: target, configuration: copy, preservingState: false)
            Logger.info("Apply to All: copied configuration from screen \(source.id) → \(target.id)", category: .screenManager)
        }
        notifyWallpaperSessionChanged()
    }
    
    func reloadAllScreens() {
        guard !isTerminating else { return }
        Logger.notice("Reloading all screens", category: .screenManager)

        let removedScreenIDs = configurationStore.pruneInvalidResourceConfigurations(
            using: SettingsManager.shared.validateConfiguration
        )

        for removedScreenID in removedScreenIDs {
            if let screen = screens.first(where: { $0.id == removedScreenID }) {
                Logger.warning("Removing invalid video configuration for screen \(removedScreenID)", category: .settings)
                releaseRuntimeSession(screen)
            }
        }

        let configurations = configurationStore.loadAll()
        configurations.forEach { primeBookmarkDisplayNames(from: $0) }

        for screen in screens {
            guard let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else {
                releaseRuntimeSession(screen)
                continue
            }

            releaseRuntimeSession(screen)
            restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
        }

        Logger.notice("All screens reloaded", category: .screenManager)
    }
    
}
