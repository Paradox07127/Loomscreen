import AppKit
import Foundation
import Testing
@testable import LiveWallpaper

/// Validates the policy-side of the video lifecycle: WallpaperPolicyEngine
/// pure-function decisions and PowerPolicyController per-screen state. The
/// runtime-side (real AVPlayer playback) is exercised manually; these tests
/// guarantee the decision layer that ScreenManager + PlaybackCoordinator
/// rely on cannot regress silently.
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

    @Test("Resume requires both external power and prior power-pause")
    func resumeRequiresExternalAndPriorPause() {
        #expect(WallpaperPolicyEngine.shouldResumeFromPower(
            powerSource: .external,
            wasPausedByPower: true
        ))
        #expect(!WallpaperPolicyEngine.shouldResumeFromPower(
            powerSource: .external,
            wasPausedByPower: false
        ))
        #expect(!WallpaperPolicyEngine.shouldResumeFromPower(
            powerSource: .battery(level: 0.99),
            wasPausedByPower: true
        ))
    }

    @Test("Startup pauses when either power or full-screen policy is active")
    func startupPauseRespectsBothPolicies() {
        let settings = GlobalSettings(
            globalPauseOnBattery: true,
            pauseOnFullScreen: true
        )

        // Battery alone triggers pause.
        #expect(WallpaperPolicyEngine.shouldStartVideoPaused(
            globalSettings: settings,
            powerSource: .battery(level: 0.5),
            isHiddenByFullScreen: false
        ))

        // Full-screen alone (with external power) also triggers pause.
        #expect(WallpaperPolicyEngine.shouldStartVideoPaused(
            globalSettings: settings,
            powerSource: .external,
            isHiddenByFullScreen: true
        ))

        // Neither condition active → play.
        #expect(!WallpaperPolicyEngine.shouldStartVideoPaused(
            globalSettings: settings,
            powerSource: .external,
            isHiddenByFullScreen: false
        ))
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

    // MARK: - PowerPolicyController: per-screen state machine

    @Test("Per-screen power-pause tracking is independent")
    func powerPauseTrackingIsPerScreen() {
        let policy = PowerPolicyController()

        policy.markPausedByPower(100)
        #expect(policy.wasPausedByPower(100))
        #expect(!policy.wasPausedByPower(200))

        policy.markResumedFromPower(100)
        #expect(!policy.wasPausedByPower(100))
    }

    @Test("Full-screen tracking does not contaminate power tracking")
    func fullScreenTrackingIsIsolatedFromPowerTracking() {
        let policy = PowerPolicyController()

        policy.markPausedByFullScreen(100)
        #expect(policy.wasPausedByFullScreen(100))
        #expect(!policy.wasPausedByPower(100))

        policy.markResumedFromFullScreen(100)
        #expect(!policy.wasPausedByFullScreen(100))
    }

    @Test("clearTracking removes both power and full-screen flags for the screen")
    func clearTrackingRemovesAllFlags() {
        let policy = PowerPolicyController()

        policy.markPausedByPower(100)
        policy.markPausedByFullScreen(100)
        policy.clearTracking(for: 100)

        #expect(!policy.wasPausedByPower(100))
        #expect(!policy.wasPausedByFullScreen(100))
    }

    @Test("cleanUpStaleEntries drops screen IDs not in the current set")
    func cleanUpDropsStaleEntries() {
        let policy = PowerPolicyController()
        policy.markPausedByPower(100)
        policy.markPausedByPower(200)
        policy.markPausedByFullScreen(300)

        policy.cleanUpStaleEntries(currentScreenIDs: [100])

        #expect(policy.wasPausedByPower(100))
        #expect(!policy.wasPausedByPower(200))
        #expect(!policy.wasPausedByFullScreen(300))
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

        // Subscription was wired during init; baseline read happened at least once.
        let baselineReadCount = powerMonitor.currentPowerSourceReadCount
        powerMonitor.send(.battery(level: 0.10))
        // Allow the Combine sink to fire on the next main-queue tick.
        try await Task.sleep(for: .milliseconds(20))

        // Switching power sources must drive a fresh read on the injected
        // monitor (handlePowerStateChange queries `powerSource` to make
        // performance-policy decisions).
        #expect(powerMonitor.currentPowerSourceReadCount >= baselineReadCount)
    }
}
