import SwiftUI
import Combine
import Observation

extension ScreenManager {
    // MARK: - Video Management

    /// Replaces the primary video while preserving per-screen settings.
    func setVideo(url: URL, bookmarkData: Data, packageEntryName: String? = nil, for screen: Screen) {
        guard !isTerminating else { return }
        recordBookmarkDisplayName(bookmarkData, name: url.lastPathComponent)
        playbackCoordinator.setVideo(
            url: url,
            bookmarkData: bookmarkData,
            packageEntryName: packageEntryName,
            for: screen
        )
    }

    @discardableResult
    func bumpTransition(for screenID: CGDirectDisplayID) -> Int {
        transitionRegistry.bumpTransition(for: screenID)
    }

    func isCurrentTransition(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool {
        transitionRegistry.isCurrentTransition(generation, for: screenID)
    }

    func applyConfiguration(_ configuration: ScreenConfiguration, to screen: Screen, preservingState: Bool = false) {
        guard !isTerminating else { return }
        playbackCoordinator.applyConfiguration(configuration, to: screen, preservingState: preservingState)
    }

    func setupVideoPlayback(url: URL, screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.setupVideoPlayback(url: url, screen: screen)
    }

    // MARK: - Icon Management
    var wallpaperSessionSummaries: [WallpaperSessionSummary] {
        screens.map { wallpaperSummary(for: $0) }
    }

    var wallpaperOverviewStatus: WallpaperOverviewStatus {
        WallpaperStatusAggregator.overview(for: wallpaperSessionSummaries)
    }

    var hasControllableWallpaperSessions: Bool {
        wallpaperSessionSummaries.contains { $0.isConfigured && $0.supportsPlaybackControl }
    }

    func wallpaperSummary(for screen: Screen) -> WallpaperSessionSummary {
        wallpaperSessionSummaryCache.summary(for: screen.id, fallback: effectiveSummary(for: screen))
    }

    /// Per-screen summary that accounts for the master render gate. With a live
    /// session we use its own summary. Without one we still report
    /// configured-but-`.off` when the master switch is off and a wallpaper is
    /// persisted — so the overview stays `.off` (and the menu-bar master switch
    /// stays enabled to turn rendering back on) instead of collapsing to
    /// `.notConfigured` now that the gate tears sessions down to free memory.
    private func effectiveSummary(for screen: Screen) -> WallpaperSessionSummary {
        if screen.runtimeSession != nil {
            return screen.wallpaperSessionSummary
        }
        if !wallpapersGloballyEnabled, let type = persistedWallpaperType(for: screen) {
            return WallpaperSessionSummary(
                wallpaperType: type,
                activity: .off,
                supportsPlaybackControl: false,
                subtitle: nil
            )
        }
        return screen.wallpaperSessionSummary
    }

    /// The wallpaper type a screen would render from its persisted
    /// configuration, or `nil` when nothing valid is assigned. Uses the same
    /// validity gate as `restoreWallpaperSession` so an empty/malformed config
    /// reads as "not configured".
    private func persistedWallpaperType(for screen: Screen) -> WallpaperType? {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              WallpaperSessionDefinition(configuration: config) != nil else { return nil }
        return config.activeWallpaper.wallpaperType
    }

    func runtimeError(for screen: Screen) -> WallpaperRuntimeError? {
        _ = wallpaperSessionStateVersion
        return transientRuntimeErrors[screen.id] ?? screen.runtimeSession?.runtimeError
    }

    func setTransientRuntimeError(_ error: WallpaperRuntimeError?, for screenID: CGDirectDisplayID) {
        let didChange: Bool
        if let error {
            didChange = transientRuntimeErrors[screenID] != error
            transientRuntimeErrors[screenID] = error
        } else {
            didChange = transientRuntimeErrors.removeValue(forKey: screenID) != nil
        }
        guard didChange else { return }

        var next = wallpaperSessionState
        next.version &+= 1
        wallpaperSessionState = next
    }

    func retryRuntimeSession(for screen: Screen) {
        Task { @MainActor [weak self, weak screen] in
            guard let self, let screen, !self.isTerminating else { return }
            await screen.runtimeSession?.retry()
            guard !self.isTerminating else { return }
            self.markWallpaperSessionStateChanged()
        }
    }

    /// Subscribes the manager to a session's error changes so the SwiftUI banner refreshes when a player or web view starts / clears a failure.
    func observeRuntimeErrors(for session: any WallpaperRuntimeSession) {
        let notify: @MainActor () -> Void = { [weak self] in
            self?.markWallpaperSessionStateChanged()
        }
        if let session = session as? VideoWallpaperSession {
            session.onRuntimeErrorChange = notify
        } else if let session = session as? AmbientWallpaperSession {
            session.onRuntimeErrorChange = notify
        }
        #if !LITE_BUILD
        if let session = session as? SceneWallpaperSession {
            session.onRuntimeErrorChange = notify
        }
        #endif
    }

    func wallpaperDisplayName(for screen: Screen) -> String? {
        guard let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              let definition = WallpaperSessionDefinition(configuration: configuration) else { return nil }

        return definition.displayName(using: { bookmarkDisplayName(for: $0) })
    }

    func bookmarkDisplayName(for bookmarkData: Data) -> String? {
        bookmarkDisplayNameCache.name(for: bookmarkData)
    }

    func currentVideoDisplayName(for screen: Screen) -> String? {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return nil }
        let cursor = config.playlistCursorIndex ?? 0
        let combined = [config.savedVideoBookmarkData].compactMap { $0 } + (config.playlistBookmarks ?? [])
        guard cursor < combined.count else {
            return config.savedVideoBookmarkData.flatMap { bookmarkDisplayName(for: $0) }
        }
        return bookmarkDisplayName(for: combined[cursor])
    }

    func recordBookmarkDisplayName(_ bookmarkData: Data, name: String?) {
        bookmarkDisplayNameCache.record(bookmarkData, name: name)
    }

    func primeBookmarkDisplayNames(from configuration: ScreenConfiguration) {
        persistence.primeDisplayNames(from: configuration)
    }

    /// Builds the next session-state snapshot and commits it iff something actually changed.
    func commitWallpaperSessionState(includePollingRefresh: Bool = false) {
        var next = wallpaperSessionState
        next.summaryCache = WallpaperSessionSummaryCache(
            entries: screens.map { ($0.id, effectiveSummary(for: $0)) }
        )
        next.isAnyPlaying = screens.contains { $0.playbackController?.isPlaying ?? false }

        let derivedChanged = next.summaryCache != wallpaperSessionState.summaryCache
            || next.isAnyPlaying != wallpaperSessionState.isAnyPlaying
        if derivedChanged {
            next.version &+= 1
            wallpaperSessionState = next
            if playbackStateSubject.value != next.isAnyPlaying {
                playbackStateSubject.send(next.isAnyPlaying)
            }
        }

        if includePollingRefresh {
            updateFullScreenFallbackPolling()
        }
    }

    func markWallpaperSessionStateChanged() {
        commitWallpaperSessionState()
    }

    func notifyWallpaperSessionChanged() {
        commitWallpaperSessionState(includePollingRefresh: true)
    }

    func updatePlaybackState() {
        commitWallpaperSessionState()
    }

    func refreshWallpaperSessionSummaryCache() {
        commitWallpaperSessionState()
    }

    func togglePlayback() {
        guard hasControllableWallpaperSessions else { return }

        // Decide from user INTENT, not actual playback: a policy-suspended
        // video reads `isPlaying == false` but the user still "intends" to
        // play, so toggling must flip intent, not chase the suppressed state.
        let anyIntendsToPlay = screens.contains { $0.playbackController?.userIntendsToPlay ?? false }

        Logger.info("Toggling global playback: \(anyIntendsToPlay ? "pausing" : "playing") all videos", category: .videoPlayer)

        for screen in screens {
            guard let playback = screen.playbackController else { continue }
            if anyIntendsToPlay {
                playback.pause()
            } else {
                playback.play()
            }
        }

        updatePlaybackState()
    }

    /// Per-screen play/pause toggle. Video sessions also post a playback-state
    /// notification that triggers a commit, but scene/HTML sessions only mutate
    /// `userIntendsToPlay`, so this commits the derived session state itself to
    /// refresh the menu-bar / inspector UI immediately.
    func togglePlayback(for screen: Screen) {
        guard let playback = screen.playbackController else { return }
        if playback.userIntendsToPlay {
            playback.pause()
        } else {
            playback.play()
        }
        updatePlaybackState()
        refreshAppNapAssertion()
    }

    /// Master render gate. Toggles whether wallpaper pipelines exist at all:
    /// disabling tears every session down to free its memory, enabling rebuilds
    /// them from persisted configuration (see `applyGlobalRenderGate`). The flag
    /// is persisted and is the single source of truth for the menu-bar master
    /// switch. Note: because sessions are destroyed rather than suspended,
    /// transient per-screen playback state (a manual pause is not persisted
    /// anywhere) is not carried across an off→on cycle — rebuilt screens follow
    /// the normal startup playback policy, exactly as on app relaunch.
    func setWallpapersEnabled(_ enabled: Bool) {
        guard !isTerminating else { return }
        wallpapersGloballyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.globallyEnabledDefaultsKey)
        Logger.info("\(enabled ? "Enabling" : "Disabling") all wallpaper rendering (master gate)", category: .screenManager)

        applyGlobalRenderGate()
        markWallpaperSessionStateChanged()
    }

    /// Apply the master gate to every screen. When enabled, builds any session
    /// that is missing (from its persisted configuration) and makes any
    /// already-live one visible, then re-runs the performance policy so the
    /// gate never decides quality/suspended itself. When disabled, fully tears
    /// each session down so its GPU textures, scene runtime, and decoded assets
    /// are released — rather than leaving a suspended-but-resident renderer
    /// holding memory. Idempotent and safe to call across launches and after
    /// new wallpapers are assigned.
    func applyGlobalRenderGate() {
        guard !isTerminating else { return }
        for screen in screens {
            if wallpapersGloballyEnabled {
                if screen.runtimeSession == nil {
                    // Rendering is permitted again — rebuild from the persisted
                    // configuration. No-op for screens without a saved wallpaper.
                    // The build path applies the current performance policy itself.
                    loadConfigurationForScreen(screen)
                } else {
                    // Already-live session (idempotent re-enable): only ensure
                    // the window is visible. Whether it runs or stays suspended
                    // is decided by the performance policy below — never a blind
                    // resume() that would override power / thermal / full-screen
                    // / app-rule state.
                    screen.runtimeSession?.show()
                }
            } else if screen.runtimeSession != nil {
                releaseRuntimeSession(screen)
            }
        }

        // Single source of truth for "how hard a live session works". Re-running
        // the policy after enabling keeps the master gate (a lifecycle axis)
        // from bypassing the performance-profile axis. Skipped while disabled —
        // there are no live sessions to target.
        if wallpapersGloballyEnabled {
            refreshPerformancePolicyForAllScreens()
        }
    }
    
    // MARK: - Desktop Picture from Frame

    func updateSetAsDesktopPicture(_ enabled: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.setAsLockScreen != enabled else { return }
        config.setAsLockScreen = enabled
        saveConfiguration(config)
    }

    /// Returns `true` when a frame extraction request was actually issued
    /// (player exists with a `currentItem`). Callers use the result to gate
    /// UI feedback so a silent no-op can't show a false success indicator.
    @discardableResult
    func extractLockScreenFrame(for screen: Screen) -> Bool {
        guard !isTerminating else { return false }
        guard let player = screen.videoPlayer?.player else { return false }

        return DesktopPictureFrameExtractor.applyCurrentFrame(
            from: player,
            screenID: screen.id,
            nsScreen: displayRegistry.findNSScreen(for: screen.id)
        )
    }

    // MARK: - Wallpaper Type Switching

    func switchToVideoWallpaper(for screen: Screen) {
        guard !isTerminating else { return }
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let previousWallpaper = config.activeWallpaper
        guard config.activateSavedVideoWallpaper() else { return }

        if previousWallpaper == config.activeWallpaper,
           screen.runtimeSession?.wallpaperType == .video {
            Logger.info("Video wallpaper already active for screen \(screen.id); keeping existing player session", category: .screenManager)
            return
        }

        saveConfiguration(config)

        loadConfigurationForScreen(screen)
    }

    /// Restore previously-applied HTML source after the user toggles the type picker back to HTML.
    func switchToHTMLWallpaper(for screen: Screen) {
        guard !isTerminating else { return }
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let previousWallpaper = config.activeWallpaper
        guard config.activateSavedHTMLWallpaper() else { return }

        if previousWallpaper == config.activeWallpaper,
           screen.runtimeSession?.wallpaperType == .html {
            Logger.info("HTML wallpaper already active for screen \(screen.id); keeping existing WKWebView session", category: .screenManager)
            return
        }

        saveConfiguration(config)
        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
    }

    /// Activate (or restore) the Monitor wallpaper for a screen when the user
    /// toggles the type picker to Monitor. Seeds a default configuration on a
    /// screen that has never had one, mirroring `switchToHTMLWallpaper`.
    func switchToMonitorWallpaper(for screen: Screen) {
        guard !isTerminating else { return }
        var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .monitor(.default)
        ).applyingDisplayDefaults(SettingsManager.shared.loadDisplayDefaults())

        let previousWallpaper = config.activeWallpaper
        config.activateSavedMonitorWallpaper()

        if previousWallpaper == config.activeWallpaper,
           screen.runtimeSession?.wallpaperType == .monitor {
            Logger.info("Monitor wallpaper already active for screen \(screen.id); keeping existing session", category: .screenManager)
            return
        }

        saveConfiguration(config)
        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
    }

    /// Persist a board configuration WITHOUT restarting the session — used both for
    /// edits made on the LIVE wallpaper (drag / add / remove / resize; the board
    /// already reflects them) and for inspector-side edits (refresh rate, mouse,
    /// reduce-motion, per-widget options). A full session rebuild would tear down
    /// the board the user is editing and churn the wallpaper lease/window for
    /// changes that all apply in place, so instead we persist and push the config
    /// into every live monitor view for this screen via its non-restarting
    /// `apply(configuration:)` (which no-ops when nothing changed, so a
    /// live-board-originated edit round-tripping back here doesn't rebuild).
    func persistMonitorConfigurationFromBoard(_ config: MonitorBoardConfiguration, for screen: Screen) {
        guard !isTerminating else { return }
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        guard case .monitor(let current) = configuration.activeWallpaper else { return }
        guard current != config else { return }
        configuration.updateMonitorConfiguration(config)
        saveConfiguration(configuration)
        // Push into the live wallpaper so an inspector-originated edit takes effect
        // immediately (the live view doesn't observe the persistence notification).
        for view in liveMonitorBoardViews(for: screen) {
            view.apply(configuration: config)
        }
        notifyWallpaperSessionChanged()
    }

    // MARK: - HTML Wallpaper (delegates to HTMLWallpaperCoordinator)

    func screensRunningSameHTMLSource(as source: HTMLSource, excluding: CGDirectDisplayID) -> [Screen] {
        htmlCoordinator.screensRunningSameSource(as: source, excluding: excluding)
    }

    func setHTMLWallpaper(
        source: HTMLSource,
        config: HTMLConfig = .default,
        forceReload: Bool = false,
        bookmarkID: UUID? = nil,
        wpeOrigin: WPEOrigin? = nil,
        for screen: Screen
    ) {
        guard !isTerminating else { return }
        htmlCoordinator.setWallpaper(
            source: source,
            config: config,
            forceReload: forceReload,
            bookmarkID: bookmarkID,
            wpeOrigin: wpeOrigin,
            for: screen
        )
    }

    func setHTMLWallpaperPreservingConfig(source: HTMLSource, for screen: Screen) {
        guard !isTerminating else { return }
        htmlCoordinator.setWallpaperPreservingConfig(source: source, for: screen)
    }

    func setHTMLWallpaper(url: String, for screen: Screen) {
        guard !isTerminating else { return }
        htmlCoordinator.setWallpaper(url: url, for: screen)
    }

    func updateHTMLConfig(_ config: HTMLConfig, for screen: Screen) {
        guard !isTerminating else { return }
        htmlCoordinator.updateConfig(config, for: screen)
    }

    /// Replace the active scene's `SceneDescriptor` (currently used by the
    /// Pro inspector to push user-edited `project.json` properties down).
    /// Restarts the wallpaper session so the renderer picks up the new
    /// overrides — there's no in-place apply seam on the WPE runtimes yet,
    /// the way HTML has `applyHTMLConfig`.
    func updateSceneDescriptor(_ descriptor: SceneDescriptor, for screen: Screen) {
        guard !isTerminating else { return }
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        guard case .scene(let current) = configuration.activeWallpaper,
              current.workshopID == descriptor.workshopID else {
            return
        }
        guard current != descriptor else { return }

        #if !LITE_BUILD
        // Fast path: if every changed property is incrementally applicable
        // (e.g. a visibility toggle), patch the live renderer instead of a full
        // reload. Falls through to the reload path when the renderer can't.
        if let sceneSession = screen.runtimeSession as? SceneWallpaperSession {
            let bindings = sceneSession.scenePropertyBindings
            if !bindings.isEmpty {
                let patch = WPEScenePropertyPatch(
                    bindingsByProperty: bindings,
                    oldValues: effectiveSceneValues(for: current, origin: configuration.wpeOrigin),
                    newValues: effectiveSceneValues(for: descriptor, origin: configuration.wpeOrigin)
                )
                if sceneSession.applyScenePropertyPatch(patch) {
                    configuration.activeWallpaper = .scene(descriptor)
                    configuration.savedSceneDescriptor = descriptor
                    saveConfiguration(configuration)
                    notifyWallpaperSessionChanged()
                    return
                }
            }
        }
        #endif

        configuration.activeWallpaper = .scene(descriptor)
        configuration.savedSceneDescriptor = descriptor
        saveConfiguration(configuration)
        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }

    #if !LITE_BUILD
    /// Effective property values (schema defaults merged with the descriptor's
    /// overrides) used to diff old vs new settings for incremental apply.
    /// Package-/source-backed scenes read `project.json` in place from the source
    /// folder (zero-cache); legacy `.cache` scenes read the extracted directory.
    private func effectiveSceneValues(
        for descriptor: SceneDescriptor,
        origin: WPEOrigin?
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        switch descriptor.assetStorage {
        case .cache:
            guard WPEPathSafety.isSafeCacheRelativePath(descriptor.cacheRelativePath),
                  let supportRoot = try? FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                  ).appendingPathComponent("LiveWallpaper", isDirectory: true) else {
                return descriptor.propertyOverrides
            }
            let cacheRoot = supportRoot.appendingPathComponent(descriptor.cacheRelativePath, isDirectory: true)
            if FileManager.default.fileExists(atPath: cacheRoot.path) {
                return WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                    descriptor: descriptor,
                    cacheRootURL: cacheRoot
                )
            }
            // Cache purged but the import source may still be resolvable — read
            // `project.json` in place so property diffing matches the render
            // path's lazy fallback. Falls back to bare overrides otherwise.
            guard let origin,
                  case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                    origin.sourceFolderBookmark, target: .transient
                  ) else {
                return descriptor.propertyOverrides
            }
            return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                    descriptor: descriptor,
                    cacheRootURL: resolved.url
                )
            }
        case .sourceDirectory, .packageSource:
            guard let origin,
                  case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                    origin.sourceFolderBookmark, target: .transient
                  ) else {
                return descriptor.propertyOverrides
            }
            return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                    descriptor: descriptor,
                    cacheRootURL: resolved.url
                )
            }
        }
    }
    #endif

    // MARK: - Metal Shader Wallpaper

    /// Matches `setSceneWallpaper` — the body only touches Core schema +
    /// session restore. The Pro-only `makeShaderSession` call is reached
    /// indirectly through `restoreWallpaperSession → activateAmbientWallpaper`
    /// where the `.metalShader` case is gated with `#if !LITE_BUILD`, so this
    /// stays ungated for Lite-side bookmark restore / decode compatibility.
    func setShaderWallpaper(source: ShaderSource, for screen: Screen) {
        guard !isTerminating else { return }
        let previousContent = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)?.activeWallpaper
        var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) ?? ScreenConfiguration(
            screenID: screen.id, wallpaper: .metalShader(source)
        ).applyingDisplayDefaults(SettingsManager.shared.loadDisplayDefaults())
        config.setShaderWallpaper(source)
        originReconciler.reconcile(
            &config,
            event: .userReplacedActiveWallpaper(previous: previousContent)
        )
        saveConfiguration(config)

        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
    }

    /// Counterpart to `switchToVideoWallpaper` / `switchToHTMLWallpaper` for
    /// the shader tab. Never auto-activates a shader the user didn't pick:
    /// if a shader is already running this is a no-op (idempotent re-entry);
    /// if the active wallpaper is something else (video / html / scene) the
    /// tab swap is honored visually — the shader gallery shows in the
    /// preview area — but no shader runtime spins up until the user clicks
    /// a preset card. Matches the "saved restore" pattern the other tabs
    /// use: silent when there's nothing to restore.
    func switchToShaderWallpaper(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        if case .metalShader = config.activeWallpaper { return }
        // Intentional no-op when active wallpaper is video / html / scene.
    }


}
