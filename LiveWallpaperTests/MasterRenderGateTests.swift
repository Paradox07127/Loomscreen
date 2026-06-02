import AppKit
import Foundation
import Testing
@testable import LiveWallpaper
import LiveWallpaperCore

/// Regression coverage for the master render gate (the menu-bar global on/off
/// switch). The gate must NOT build a live session while disabled — it keeps
/// the configuration persisted and rebuilds on enable — so a screen with a
/// saved wallpaper stays reported as configured-but-`.off` (keeping the switch
/// enabled) rather than collapsing to `.notConfigured`, which would soft-lock
/// the user out of ever turning wallpapers back on.
@Suite("Master render gate")
@MainActor
struct MasterRenderGateTests {

    /// Mirrors `ScreenManager.globallyEnabledDefaultsKey` (private). Setting it
    /// before constructing the manager makes the gate load in a known state
    /// without building anything.
    private static let gateDefaultsKey = "loomscreen.wallpapers.globallyEnabled.v1"

    private static func withGate(_ enabled: Bool, _ body: () throws -> Void) rethrows {
        let original = UserDefaults.standard.object(forKey: gateDefaultsKey)
        UserDefaults.standard.set(enabled, forKey: gateDefaultsKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: gateDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: gateDefaultsKey)
            }
        }
        try body()
    }

    private static func makeManager(screen: Screen) -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: true,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen])
        ))
    }

    @Test("Gate off does not build a session yet reports the screen as configured-but-off")
    func gateOffSkipsBuildButReportsOff() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: screen.id, wallpaper: .metalShader(.waves))
        ])

        try Self.withGate(false) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            #expect(manager.wallpapersGloballyEnabled == false)

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            // Core fix: rendering never started, so no session/renderer memory.
            #expect(liveScreen.runtimeSession == nil, "Gate off must not build a live session")

            // Soft-lock guard: the configured screen is reported as `.off`, so
            // the overview is `.off` (switch enabled), NOT `.notConfigured`.
            let summary = manager.wallpaperSummary(for: liveScreen)
            #expect(summary.activity == .off)
            #expect(summary.isConfigured)
            #expect(manager.wallpaperOverviewStatus == .off)
            #expect(manager.wallpaperOverviewStatus != .notConfigured)
        }
    }

    @Test("Gate off with no saved wallpaper still reports not-configured")
    func gateOffWithoutConfigReportsNotConfigured() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([])

        try Self.withGate(false) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            #expect(liveScreen.runtimeSession == nil)
            // No wallpaper assigned: must NOT masquerade as `.off`; the switch
            // is correctly disabled when there is nothing to enable.
            #expect(manager.wallpaperSummary(for: liveScreen).activity == .inactive)
            #expect(manager.wallpaperOverviewStatus == .notConfigured)
        }
    }

    @Test("Assigning a wallpaper while the gate is off flips the overview to .off (no stale cache)")
    func assigningWallpaperWhileOffRefreshesOverview() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        // Start with nothing configured anywhere.
        SettingsManager.shared.replaceAllConfigurations([])

        try Self.withGate(false) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            // Precondition: nothing configured, switch would be disabled.
            #expect(manager.wallpaperOverviewStatus == .notConfigured)

            // Assign a shader wallpaper while the gate is off: it must persist
            // without building a session, and the derived overview must refresh
            // to `.off` so the menu-bar switch becomes usable again — otherwise
            // a stale `.notConfigured` cache would soft-lock the switch.
            manager.setShaderWallpaper(source: .waves, for: liveScreen)

            #expect(liveScreen.runtimeSession == nil, "Gate off must not build a session")
            #expect(manager.wallpaperSummary(for: liveScreen).activity == .off)
            #expect(manager.wallpaperOverviewStatus == .off)
        }
    }

    @Test("Enabling the gate rebuilds the session from persisted config and makes it live")
    func enablingGateRebuildsAndRunsPolicy() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: screen.id, wallpaper: .metalShader(.waves))
        ])

        try Self.withGate(false) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            #expect(liveScreen.runtimeSession == nil, "Gate off must not build a session")

            // Enable: the lifecycle axis rebuilds the missing session from
            // persisted config; the performance policy (not a blind resume)
            // then drives it live, so the overview leaves the `.off` state.
            manager.setWallpapersEnabled(true)

            #expect(manager.wallpapersGloballyEnabled)
            #expect(liveScreen.runtimeSession != nil, "Enabling must rebuild the session")
            #expect(manager.wallpaperOverviewStatus != .off)
            #expect(manager.wallpaperOverviewStatus != .notConfigured)

            // Round-trip back off must tear the rebuilt session down again.
            manager.setWallpapersEnabled(false)
            #expect(liveScreen.runtimeSession == nil, "Disabling must release the rebuilt session")
        }
    }

    @Test("Re-applying the gate while already enabled keeps the same live session (show-only branch)")
    func reapplyingGateKeepsLiveSession() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: screen.id, wallpaper: .metalShader(.waves))
        ])

        try Self.withGate(true) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            // Gate on + restore-on-refresh builds the session at launch.
            #expect(liveScreen.runtimeSession != nil, "Gate on must build the session")
            let builtIdentity = liveScreen.runtimeSession.map { ObjectIdentifier($0 as AnyObject) }

            // Idempotent re-apply exercises the already-live `show()`-only
            // branch: the session must be preserved (not rebuilt, not resumed
            // blindly) and the performance policy left in charge.
            manager.applyGlobalRenderGate()

            #expect(liveScreen.runtimeSession != nil, "Re-enabling must not tear a live session down")
            #expect(liveScreen.runtimeSession.map { ObjectIdentifier($0 as AnyObject) } == builtIdentity,
                    "An already-live session must be reused, not rebuilt")
            #expect(manager.wallpaperOverviewStatus != .off)
            #expect(manager.wallpaperOverviewStatus != .notConfigured)
        }
    }
}
