import AppKit
import Foundation
import Testing
@testable import LiveWallpaper

/// Validates the policy-side of the video lifecycle: WallpaperPolicyEngine
/// pure-function decisions and the `VideoWallpaperSession` intent state
/// machine. The runtime-side (real AVPlayer playback) is exercised manually;
/// these tests guarantee the decision layer that ScreenManager +
/// PlaybackCoordinator rely on cannot regress silently.
@Suite("Video session lifecycle policy")
@MainActor
struct VideoSessionLifecycleTests {

    // MARK: - WallpaperPolicyEngine: pause-on-power decisions

    @Test("External power never pauses, regardless of settings")
    func externalPowerNeverPauses() {
        let aggressiveSettings = GlobalSettings(globalPauseOnBattery: true, minimumBatteryLevel: 0.95)
        let decision = WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: aggressiveSettings,
            powerSource: .external
        )
        #expect(decision == false)
    }

    @Test("Global pause-on-battery wins over level threshold when battery is in use")
    func globalPauseWinsOverLevel() {
        let settings = GlobalSettings(globalPauseOnBattery: true, minimumBatteryLevel: 0.05)
        let decision = WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: settings,
            powerSource: .battery(level: 0.95)
        )
        #expect(decision == true)
    }

    @Test("Level threshold pauses below the configured floor")
    func levelThresholdPausesBelowFloor() {
        let settings = GlobalSettings(globalPauseOnBattery: false, minimumBatteryLevel: 0.30)
        let belowFloor = WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: settings,
            powerSource: .battery(level: 0.20)
        )
        let atFloor = WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: settings,
            powerSource: .battery(level: 0.30)
        )
        let aboveFloor = WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: settings,
            powerSource: .battery(level: 0.50)
        )
        #expect(belowFloor == true)
        #expect(atFloor == false, "Threshold is exclusive — playing at exactly the floor")
        #expect(aboveFloor == false)
    }

    @Test("Full-screen policy is gated by the user setting")
    func fullScreenPolicyHonoursSetting() {
        let disabled = GlobalSettings(pauseOnFullScreen: false)
        let enabled = GlobalSettings(pauseOnFullScreen: true)

        #expect(!WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: disabled,
            isHiddenByFullScreen: true
        ))
        #expect(WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: enabled,
            isHiddenByFullScreen: true
        ))
        #expect(!WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: enabled,
            isHiddenByFullScreen: false
        ))
    }

    // MARK: - ScreenManager wiring: power changes flow through the injected monitor

    @Test("ScreenManager subscribes the injected PowerMonitoring publisher and reacts to changes")
    func screenManagerReactsToInjectedPowerMonitorEvents() async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager wiring test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        let powerMonitor = FakePowerMonitor(initialPowerSource: .external)
        _ = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: powerMonitor,
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen])
        ))

        let baselineReadCount = powerMonitor.currentPowerSourceReadCount
        powerMonitor.send(.battery(level: 0.10))
        try await Task.sleep(for: .milliseconds(20))

        #expect(powerMonitor.currentPowerSourceReadCount >= baselineReadCount)
    }

    // MARK: - VideoWallpaperSession intent state machine (single authority)

    /// Asserts the core safety invariant: a performance-policy profile NEVER
    /// mutates `userIntendsToPlay`; only manual play/pause do. Uses a player
    /// built with `loadImmediately: false` so no AVPlayer/window is created —
    /// the intent flag is synchronous and independent of real playback.
    @Test("Policy profiles never mutate intent; manual play/pause own it")
    func videoIntentStateMachine() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/master-gate-intent-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            loadImmediately: false
        )
        let session = VideoWallpaperSession(player: player)
        defer { session.cleanup() }

        // Fresh session intends to play.
        #expect(session.userIntendsToPlay)

        // Policy suspend/restore must not touch intent.
        session.applyPerformanceProfile(.suspended)
        #expect(session.userIntendsToPlay)
        session.applyPerformanceProfile(.quality)
        #expect(session.userIntendsToPlay)

        // Manual pause clears intent.
        session.pause()
        #expect(!session.userIntendsToPlay)

        // A policy `.quality` must NOT resume a manually-paused video.
        session.applyPerformanceProfile(.suspended)
        #expect(!session.userIntendsToPlay)
        session.applyPerformanceProfile(.quality)
        #expect(!session.userIntendsToPlay)

        // Manual play restores intent.
        session.play()
        #expect(session.userIntendsToPlay)
    }
}
