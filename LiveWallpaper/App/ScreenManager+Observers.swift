import SwiftUI
import Combine
import Observation

extension ScreenManager {
    // MARK: - Observers Setup
    func setupPowerMonitoring() {
        powerMonitor.powerSourcePublisher
            .sink { [weak self] powerSource in
                self?.handlePowerStateChange(powerSource)
            }
            .store(in: &cleanupTasks)
        
        let initialPowerSource = powerMonitor.currentPowerSource
        handlePowerStateChange(initialPowerSource)
    }
    
    func setupScreenObservers() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .throttle(for: .seconds(1.0), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.handleScreenParameterChange()
            }
            .store(in: &cleanupTasks)

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Logger.info(
                    "Thermal state changed to \(ProcessInfo.processInfo.thermalState); refreshing wallpaper performance policy",
                    category: .powerMonitor
                )
                self.refreshPerformancePolicyForAllScreens()
            }
            .store(in: &cleanupTasks)

        // Low Power Mode toggles flip `GameModeDetector.shared.isActive` without
        // changing the frontmost app, so we need a dedicated subscription
        // here — otherwise the policy refresh would wait for the next
        // unrelated event. The notification name is the AppKit/Foundation
        // Obj-C constant; Swift doesn't surface a typed alias on macOS.
        NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Logger.info(
                    "Power state changed (Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)); refreshing wallpaper performance policy",
                    category: .powerMonitor
                )
                self.refreshPerformancePolicyForAllScreens()
            }
            .store(in: &cleanupTasks)

        // GameMode + per-app pause rules (frontmost trigger) piggyback on
        // frontmost-app activations — flipping to / from Steam, a game, or a
        // rule-listed app re-evaluates the policy.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshPerformancePolicyForAllScreens()
            }
            .store(in: &cleanupTasks)

        // Per-app pause rules with the "while running" trigger need to react to
        // launch / quit too (an app can start without becoming frontmost). These
        // fire only on actual launch/quit, so there's no idle cost.
        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else { return }
            // Cheap no-op unless a "running"-trigger rule exists.
            guard SettingsManager.shared.loadGlobalSettings()
                .applicationPerformanceRules.contains(where: { $0.trigger == .running }) else { return }
            self.refreshPerformancePolicyForAllScreens()
        }
        .store(in: &cleanupTasks)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                self?.handleSystemSleep()
            }
            .store(in: &cleanupTasks)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.handleSystemWake()
            }
            .store(in: &cleanupTasks)

        // Display sleep（仅显示器睡眠，整机仍在跑）。区别于上面的 willSleep/didWake
        // （整机睡眠）和下面的 screenIsLocked（用户锁屏，显示器仍亮）。
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in
                self?.handleDisplaySleep()
            }
            .store(in: &cleanupTasks)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in
                self?.handleDisplayWake()
            }
            .store(in: &cleanupTasks)

        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .sink { [weak self] _ in
                self?.handleScreenLocked()
            }
            .store(in: &cleanupTasks)

        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .sink { [weak self] _ in
                self?.handleScreenUnlocked()
            }
            .store(in: &cleanupTasks)
    }

    private func handleScreenLocked() {
        Logger.info("Screen locked — suspending wallpaper sessions", category: .lifecycle)
        setUserAbsence(.screenLocked, present: true)
    }

    private func handleDisplaySleep() {
        Logger.info("Display asleep — suspending wallpaper sessions", category: .lifecycle)
        setUserAbsence(.displaySleep, present: true)
    }

    private func handleDisplayWake() {
        Logger.info("Display awake — restoring wallpaper sessions", category: .lifecycle)
        setUserAbsence(.displaySleep, present: false)
    }

    private func handleScreenUnlocked() {
        Logger.info("Screen unlocked — restoring wallpaper sessions", category: .lifecycle)
        setUserAbsence(.screenLocked, present: false)
    }

    /// Lock screen and display sleep both mean "user is not watching". They
    /// fold into the effective performance profile via `isUserAbsent`, so a
    /// single policy refresh suspends or restores every session (respecting
    /// each video's `userIntendsToPlay`) — no separate pause/resume overlay.
    private func setUserAbsence(_ reason: UserAbsenceReason, present: Bool) {
        let changed = present
            ? userAbsenceReasons.insert(reason).inserted
            : (userAbsenceReasons.remove(reason) != nil)
        guard changed else { return }
        refreshMonitorOverlayVisibility()
        refreshPerformancePolicyForAllScreens()
    }

    private func handleScreenParameterChange() {
        guard !isTerminating else { return }
        let current = ScreenConfigurationSignature.currentLayout()
        if current == lastScreenSignatures && !screens.isEmpty {
            Logger.debug("Screen parameters unchanged — skipping refresh", category: .screenManager)
            return
        }
        lastScreenSignatures = current

        refreshRateCache.removeAll()
        refreshScreens(preserveRuntimeSessions: true)

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !self.isTerminating else { return }
            self.updateAllWindowFrames()
            try? await Task.sleep(for: .milliseconds(500))
            guard !self.isTerminating else { return }
            self.updateAllWindowFrames()
        }

    }

    func updateAllWindowFrames() {
        guard !isTerminating else { return }
        for screen in screens {
            if let nsScreen = displayRegistry.findNSScreen(for: screen.id) {
                screen.updateRuntimeFrame(to: nsScreen.frame)
            } else {
                Logger.warning("Could not find NSScreen for screen ID \(screen.id), using stored frame", category: .screenManager)
                screen.updateRuntimeFrame(to: screen.frame)
            }
        }
        playbackCoordinator.refreshVideoRendering()
        reconcileMonitorOverlays()
    }
    
    func setupFullScreenDetection() {
        observeFullScreenChanges()
        fullScreenDetector.checkNow()
        handleFullScreenChange(fullScreenDetector.hiddenScreens)
    }

    private func observeFullScreenChanges() {
        fullScreenTrackingGeneration &+= 1
        let generation = fullScreenTrackingGeneration
        withObservationTracking {
            _ = fullScreenDetector.hiddenScreens
            _ = fullScreenDetector.occludedScreens
            // Adaptive throttle reacts to partial coverage below the 0.85
            // pause cutoff, so track the (quantized) fraction too.
            _ = fullScreenDetector.occlusionFractions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isTerminating,
                      self.fullScreenTrackingGeneration == generation else { return }
                self.handleFullScreenChange(self.fullScreenDetector.hiddenScreens)
                self.observeFullScreenChanges()
            }
        }
    }

    /// Full-screen / window-occlusion changes fold into the effective profile
    /// like every other condition; a single policy refresh applies the unified
    /// play/pause decision. The `hiddenScreens` snapshot is now informational —
    /// the policy reads the detector live.
    private func handleFullScreenChange(_ hiddenScreens: [CGDirectDisplayID: Bool]) {
        refreshMonitorOverlayVisibility()
        refreshPerformancePolicyForAllScreens()
    }

    // MARK: - Power Management
    /// Power changes no longer carry their own play/pause logic — they fold
    /// into the effective performance profile like every other condition, so a
    /// single refresh applies the unified decision (`userIntendsToPlay` for
    /// video, profile for ambient) across all screens.
    private func handlePowerStateChange(_ powerSource: PowerMonitor.PowerSource) {
        refreshPerformancePolicyForAllScreens()
    }

    /// Single source of truth for resolving + applying the performance policy to
    /// one screen. Every raw signal is gathered here (via `policyInputs`), so no
    /// other type re-assembles the rule inputs — `PlaybackCoordinator` calls back
    /// into this instead of duplicating the gathering.
    @discardableResult
    func applyPerformancePolicy(to screen: Screen) -> WallpaperPerformanceProfile {
        let settings = SettingsManager.shared.loadGlobalSettings()
        let profile = resolveAndApplyPerformanceState(
            to: screen,
            settings: settings,
            applicationRuleActive: currentApplicationRuleActive(settings),
            frontmostExcluded: ApplicationPerformanceRuleEngine.isFrontmostExcluded(for: settings)
        )
        refreshAppNapAssertion()
        return profile
    }

    /// Resolves the universal suspend/quality profile and applies it together
    /// with the scene-only adaptive frame-rate throttle — the single place that
    /// pairs the two so a future edit can't drift the all-screens and
    /// single-screen paths apart. Context (`settings` and the rule flags) is
    /// passed in so the all-screens loop computes it once.
    @discardableResult
    private func resolveAndApplyPerformanceState(
        to screen: Screen,
        settings: GlobalSettings,
        applicationRuleActive: Bool,
        frontmostExcluded: Bool
    ) -> WallpaperPerformanceProfile {
        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: policyInputs(
                for: screen,
                applicationRuleActive: applicationRuleActive,
                frontmostExcluded: frontmostExcluded
            ),
            settings: settings
        )
        screen.runtimeSession?.applyPerformanceProfile(profile)
        if profile == .suspended {
            suspendedScreenIDs.insert(screen.id)
        } else {
            suspendedScreenIDs.remove(screen.id)
        }
        applyAdaptiveFrameRate(to: screen, settings: settings)
        return profile
    }

    /// Layers the adaptive background frame-rate throttle on top of the binary
    /// play/pause profile. Pixel-identical; only the presented frame *rate*
    /// changes, which on Apple Silicon is the dominant GPU-power driver. Scene
    /// renderer only — the video path uses a separate composition cap. No-op in
    /// Lite (no scene renderer).
    private func applyAdaptiveFrameRate(to screen: Screen, settings: GlobalSettings) {
        #if !LITE_BUILD
        guard let scene = screen.runtimeSession as? SceneWallpaperSession,
              let controller = scene.frameRateController else {
            adaptiveFrameRateOcclusionThrottled[screen.id] = nil
            return
        }
        // Disabling the setting must actively release any live throttle, not
        // just stop computing one.
        guard settings.adaptiveFrameRateEnabled else {
            adaptiveFrameRateOcclusionThrottled[screen.id] = nil
            controller.setAdaptiveFrameRateThrottle(false)
            return
        }
        let occlusionThrottled = AdaptiveFrameRatePolicy.shouldThrottleForOcclusion(
            occlusionFraction: fullScreenDetector.occlusionFraction(for: screen.id),
            currentlyThrottled: adaptiveFrameRateOcclusionThrottled[screen.id] ?? false
        )
        adaptiveFrameRateOcclusionThrottled[screen.id] = occlusionThrottled
        let shouldThrottle = AdaptiveFrameRatePolicy.shouldThrottle(
            enabled: true,
            occlusionThrottled: occlusionThrottled,
            onBattery: powerMonitor.currentPowerSource.isOnBattery,
            pausesOnBattery: settings.globalPauseOnBattery
        )
        controller.setAdaptiveFrameRateThrottle(shouldThrottle)
        #endif
    }

    /// Snapshots the current *raw* system state for `screen`. The `GlobalSettings`
    /// gating lives in `WallpaperPolicyEngine`, so detector/state readings are
    /// passed through ungated.
    private func policyInputs(
        for screen: Screen,
        applicationRuleActive: Bool,
        frontmostExcluded: Bool
    ) -> WallpaperPolicyInputs {
        WallpaperPolicyInputs(
            powerSource: powerMonitor.currentPowerSource,
            isHiddenByFullScreen: fullScreenDetector.isDesktopHidden(for: screen.id),
            isWindowOccluding: fullScreenDetector.isDesktopOccluded(for: screen.id),
            isApplicationRuleActive: applicationRuleActive,
            thermalState: ProcessInfo.processInfo.thermalState,
            isGameModeActive: GameModeDetector.shared.isActive,
            isUserAbsent: isUserAbsent,
            isUnderMemoryPressure: isUnderMemoryPressure,
            isFrontmostExcludedByRule: frontmostExcluded
        )
    }

    private func currentApplicationRuleActive(_ globalSettings: GlobalSettings) -> Bool {
        ApplicationPerformanceRuleEngine.isActive(for: globalSettings)
    }

    func refreshPerformancePolicyForAllScreens() {
        let settings = SettingsManager.shared.loadGlobalSettings()
        let applicationRuleActive = currentApplicationRuleActive(settings)
        let frontmostExcluded = ApplicationPerformanceRuleEngine.isFrontmostExcluded(for: settings)
        for screen in screens {
            resolveAndApplyPerformanceState(
                to: screen,
                settings: settings,
                applicationRuleActive: applicationRuleActive,
                frontmostExcluded: frontmostExcluded
            )
        }
        // Suspend/resume transitions just changed which screens are actually
        // drawing, so re-evaluate the App Nap exemption against the new profiles.
        refreshAppNapAssertion()
        // A policy refresh always commits the derived session state, so observers
        // can't leave the SwiftUI layer out of sync with the render loops by
        // forgetting a trailing updatePlaybackState() call.
        commitWallpaperSessionState()
    }

    /// Hold an activity assertion whenever ≥1 wallpaper session is actively
    /// rendering, so macOS doesn't App-Nap our background render loop down to
    /// ~1fps when the user focuses another window. The allowing-idle-sleep
    /// variant deliberately avoids a `PreventUserIdleSystemSleep` assertion, so
    /// the Mac can still sleep on its own schedule. A session that the
    /// performance policy has suspended (`.suspended` — occlusion, full-screen,
    /// game mode, battery, memory pressure, user absence) is excluded because it
    /// is not drawing. The guard/if-let pair makes an unchanged desired state a
    /// no-op, so policy refreshes do not churn begin/end activity calls.
    func refreshAppNapAssertion() {
        let isRendering = screens.contains {
            $0.runtimeSession != nil
                && !suspendedScreenIDs.contains($0.id)
                && ($0.playbackController?.userIntendsToPlay ?? true)
        }
        if isRendering {
            guard renderingActivityToken == nil else { return }
            renderingActivityToken = ProcessInfo.processInfo.beginActivity(
                options: WallpaperRenderingActivityPolicy.options,
                reason: "Rendering live wallpaper"
            )
        } else if let token = renderingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            renderingActivityToken = nil
        }
    }

    func updateFullScreenFallbackPolling() {
        guard !isTerminating else {
            // Bottom-level fail-closed gate: settings/backup callbacks are not
            // owned by `cleanupTasks` and may arrive after termination teardown.
            fullScreenDetector.setFallbackPollingEnabled(false)
            return
        }
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let hasConfiguredSessions = wallpaperSessionSummaries.contains { $0.isConfigured }
        let hasConfiguredSceneSessions = wallpaperSessionSummaries.contains {
            $0.isConfigured && $0.wallpaperType == .scene
        }
        let wallpaperPolicyNeedsPolling = WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: globalSettings,
            hasConfiguredWallpaperSessions: hasConfiguredSessions,
            hasConfiguredSceneSessions: hasConfiguredSceneSessions
        )
        let shouldEnablePolling = wallpaperPolicyNeedsPolling || hasEnabledDesktopMonitorOverlay

        fullScreenDetector.setFallbackPollingEnabled(shouldEnablePolling)
    }

    func handleGlobalSettingsChanged() {
        guard !isTerminating else { return }
        updateFullScreenFallbackPolling()
        refreshPerformancePolicyForAllScreens()
    }
    
    // MARK: - System Events
    private func handleSystemSleep() {
        Logger.info("System sleep detected", category: .lifecycle)
        setUserAbsence(.systemSleep, present: true)
    }

    private func handleSystemWake() {
        Logger.info("System wake detected", category: .lifecycle)
        refreshScreens()
        powerMonitor.refreshPowerStatus()
        setUserAbsence(.systemSleep, present: false)
    }

    func captureDesktopSnapshotsForLockIfNeeded() {
        guard !isTerminating else { return }
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        guard globalSettings.preservePlaybackOnLock else { return }

        for screen in screens {
            guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                  config.wallpaperType == .video,
                  config.setAsLockScreen else { continue }
            extractLockScreenFrame(for: screen)
        }
    }
    
}
