import AppKit
import Foundation
import Testing
@testable import LiveWallpaper
import LiveWallpaperCore

/// Prevents the global render gate from collapsing configured screens to `notConfigured`, which would disable re-enabling.
@Suite("Master render gate")
@MainActor
struct MasterRenderGateTests {

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
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
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

        Self.withGate(false) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            #expect(manager.wallpapersGloballyEnabled == false)

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            #expect(liveScreen.runtimeSession == nil, "Gate off must not build a live session")

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

        Self.withGate(false) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            #expect(liveScreen.runtimeSession == nil)
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

        SettingsManager.shared.replaceAllConfigurations([])

        Self.withGate(false) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            #expect(manager.wallpaperOverviewStatus == .notConfigured)

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

        Self.withGate(false) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            #expect(liveScreen.runtimeSession == nil, "Gate off must not build a session")

            manager.setWallpapersEnabled(true)

            #expect(manager.wallpapersGloballyEnabled)
            #expect(liveScreen.runtimeSession != nil, "Enabling must rebuild the session")
            #expect(manager.wallpaperOverviewStatus != .off)
            #expect(manager.wallpaperOverviewStatus != .notConfigured)

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

        Self.withGate(true) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            #expect(liveScreen.runtimeSession != nil, "Gate on must build the session")
            let builtIdentity = liveScreen.runtimeSession.map { ObjectIdentifier($0 as AnyObject) }

            manager.applyGlobalRenderGate()

            #expect(liveScreen.runtimeSession != nil, "Re-enabling must not tear a live session down")
            #expect(liveScreen.runtimeSession.map { ObjectIdentifier($0 as AnyObject) } == builtIdentity,
                    "An already-live session must be reused, not rebuilt")
            #expect(manager.wallpaperOverviewStatus != .off)
            #expect(manager.wallpaperOverviewStatus != .notConfigured)
        }
    }
}
