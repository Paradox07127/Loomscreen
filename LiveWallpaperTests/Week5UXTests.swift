import Testing
import Foundation
import CoreLocation
import LiveWallpaperCore
@testable import LiveWallpaper

// MARK: - Task 5.2 (Dock toggle) + 5.3 (Weather location) + 5.1 (Shortcuts)
//
// Each suite snapshots `GlobalSettings`/`Configurations` before mutating and
// restores them after — same pattern as `ScreenManagerCoordinationTests`,
// so the developer's actual app data isn't clobbered when this runs locally.

@Suite("GlobalSettings: Week 5 fields") @MainActor
struct GlobalSettingsWeek5Tests {

    @Test("Dock visibility round-trips through encode/decode")
    func dockVisibilityRoundTrips() throws {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.showInDock = true
        SettingsManager.shared.saveGlobalSettings(settings)

        let reloaded = SettingsManager.shared.loadGlobalSettings()
        #expect(reloaded.showInDock == true)

        settings.showInDock = false
        SettingsManager.shared.saveGlobalSettings(settings)
        #expect(SettingsManager.shared.loadGlobalSettings().showInDock == false)
    }

    @Test("Legacy settings without showInDock decode safely")
    func legacySettingsWithoutShowInDockDecodeSafely() throws {
        let legacyJSON: String = """
        {
          "globalPauseOnBattery": false,
          "preservePlaybackOnLock": false,
          "startOnLogin": false,
          "defaultFrameRateLimit": 60,
          "pauseOnFullScreen": true,
          "recentWPEImports": []
        }
        """
        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
        #expect(decoded.showInDock == false)
        #expect(decoded.weatherLocation == .default)
        #expect(decoded.globalShortcuts.isEmpty)
    }

    @Test("Weather location preference round-trips through encode/decode")
    func weatherLocationPreferenceRoundTrips() throws {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(
            source: .manual,
            manual: .init(latitude: 35.6762, longitude: 139.6503, name: "Tokyo, Japan")
        )
        SettingsManager.shared.saveGlobalSettings(settings)

        let reloaded = SettingsManager.shared.loadGlobalSettings()
        #expect(reloaded.weatherLocation.source == .manual)
        #expect(reloaded.weatherLocation.manual?.name == "Tokyo, Japan")
        #expect(abs((reloaded.weatherLocation.manual?.latitude ?? 0) - 35.6762) < 0.0001)
    }

    @Test("Shortcut bindings round-trip through encode/decode")
    func shortcutBindingsRoundTrip() throws {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.globalShortcuts = [
            GlobalShortcutAction.togglePlayback.rawAction:
                GlobalShortcutBinding(keyCode: 49, modifiers: [.command, .shift]),
            GlobalShortcutAction.nextWallpaper.rawAction: nil,
            GlobalShortcutAction.toggleMute.rawAction:
                GlobalShortcutBinding(keyCode: 46, modifiers: [.option])
        ]
        SettingsManager.shared.saveGlobalSettings(settings)

        let reloaded = SettingsManager.shared.loadGlobalSettings()
        let toggle = reloaded.globalShortcuts[GlobalShortcutAction.togglePlayback.rawAction]
        #expect(toggle??.keyCode == 49)
        #expect(toggle??.modifiers == [.command, .shift])

        let next = reloaded.globalShortcuts[GlobalShortcutAction.nextWallpaper.rawAction]
        #expect(next == .some(nil))

        let mute = reloaded.globalShortcuts[GlobalShortcutAction.toggleMute.rawAction]
        #expect(mute??.modifiers == [.option])
    }
}

@Suite("GlobalShortcutBinding: rendering & defaults")
struct GlobalShortcutBindingTests {

    @Test("Default bindings cover every action")
    func defaultBindingsCoverEveryAction() {
        for action in GlobalShortcutAction.allCases {
            let binding = GlobalShortcutAction.defaultBinding(for: action)
            #expect(binding != nil, "Action \(action.rawValue) ships without a default binding")
            #expect(binding?.modifiers.contains(.shift) == true || binding?.modifiers.contains(.control) == true,
                "Default binding for \(action.rawValue) should include a modifier to avoid stealing a plain key")
        }
    }

    @Test("Display string includes modifier symbols and key name")
    func displayStringFormatsCorrectly() {
        let binding = GlobalShortcutBinding(keyCode: 49, modifiers: [.control, .shift])
        let rendered = binding.displayString
        #expect(rendered.contains("⌃"))
        #expect(rendered.contains("⇧"))
        #expect(rendered.contains("Space"))
    }

    @Test("Arrow key codes resolve to arrow glyphs")
    func arrowKeyCodesResolveToArrowGlyphs() {
        #expect(GlobalShortcutBinding.keyName(for: 124) == "→")
        #expect(GlobalShortcutBinding.keyName(for: 123) == "←")
        #expect(GlobalShortcutBinding.keyName(for: 125) == "↓")
        #expect(GlobalShortcutBinding.keyName(for: 126) == "↑")
    }

    @Test("Letter key codes resolve to uppercase letter")
    func letterKeyCodesResolveToUppercaseLetter() {
        #expect(GlobalShortcutBinding.keyName(for: 46) == "M")
        #expect(GlobalShortcutBinding.keyName(for: 0) == "A")
        #expect(GlobalShortcutBinding.keyName(for: 31) == "O")
    }
}

@Suite("WeatherLocationProvider: fallback chain") @MainActor
struct WeatherLocationProviderFallbackTests {

    @Test("Manual source returns the persisted coordinate")
    func manualSourceReturnsPersistedCoordinate() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(
            source: .manual,
            manual: .init(latitude: 51.5074, longitude: -0.1278, name: "London, UK")
        )
        SettingsManager.shared.saveGlobalSettings(settings)

        let provider = WeatherLocationProvider()
        let resolution = await provider.resolveCoordinate()

        #expect(resolution.resolvedSource == .manual)
        #expect(resolution.coordinate?.latitude == 51.5074)
        #expect(resolution.displayName?.contains("London") == true)
    }

    @Test("Manual without saved coord reports an actionable error and no coordinate")
    func manualWithoutSavedCoordReportsError() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .manual, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        let provider = WeatherLocationProvider()
        let resolution = await provider.resolveCoordinate()

        #expect(resolution.resolvedSource == .manual)
        #expect(resolution.coordinate == nil)
        #expect(resolution.error != nil)
    }

    @Test("Off source short-circuits to unresolved without touching any backend")
    func offSourceReturnsUnresolved() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .off, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        let provider = WeatherLocationProvider()
        let resolution = await provider.resolveCoordinate()

        #expect(resolution == .unresolved)
    }

    @Test("Legacy ipGeolocation rawValue migrates to coreLocation on decode")
    func legacyIPGeolocationMigratesToCoreLocation() throws {
        let legacyJSON = #"{"source":"ipGeolocation"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WeatherLocationPreference.self, from: legacyJSON)
        #expect(decoded.source == .coreLocation)
    }

    @Test("Resolution equality compares coordinates with epsilon")
    func resolutionEqualityComparesCoordinatesWithEpsilon() {
        let a = WeatherLocationResolution(
            coordinate: CLLocationCoordinate2D(latitude: 1.0, longitude: 2.0),
            resolvedSource: .manual,
            displayName: "X",
            error: nil
        )
        let b = WeatherLocationResolution(
            coordinate: CLLocationCoordinate2D(latitude: 1.0, longitude: 2.0),
            resolvedSource: .manual,
            displayName: "X",
            error: nil
        )
        #expect(a == b)

        let c = WeatherLocationResolution(
            coordinate: CLLocationCoordinate2D(latitude: 1.1, longitude: 2.0),
            resolvedSource: .manual,
            displayName: "X",
            error: nil
        )
        #expect(a != c)
    }
}
