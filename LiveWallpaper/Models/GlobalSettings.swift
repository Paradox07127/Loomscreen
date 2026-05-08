import Foundation

struct GlobalSettings: Codable {
    var globalPauseOnBattery: Bool
    var preservePlaybackOnLock: Bool
    var startOnLogin: Bool
    var minimumBatteryLevel: Double?
    var defaultFrameRateLimit: FrameRateLimit
    var pauseOnFullScreen: Bool
    /// When true, the app activation policy is `.regular` so the app shows
    /// in the Dock and Cmd+Tab list. When false (default), the app remains
    /// `.accessory` (menu-bar only). Toggled live; no relaunch required.
    var showInDock: Bool
    /// User preferences for the weather location pipeline. See
    /// `WeatherLocationPreference` for the full source-resolution chain.
    var weatherLocation: WeatherLocationPreference
    /// User-customised global keyboard shortcuts. `nil` value means the
    /// shortcut is unbound; missing key means default binding still applies.
    var globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?]
    /// LRU of recently imported Wallpaper Engine projects (capped at 20 by
    /// `SettingsManager.recordWPEImport(_:)`). Most recent at index 0.
    var recentWPEImports: [WPEHistoryEntry] = []

    init(
        // Default `false` so a freshly-installed or reset app plays its
        // wallpaper out of the box even when running on battery — power
        // savers can opt in via General Settings.
        globalPauseOnBattery: Bool = false,
        preservePlaybackOnLock: Bool = false,
        startOnLogin: Bool = false,
        minimumBatteryLevel: Double? = nil,
        defaultFrameRateLimit: FrameRateLimit = .fps60,
        pauseOnFullScreen: Bool = true,
        showInDock: Bool = false,
        weatherLocation: WeatherLocationPreference = .default,
        globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?] = [:],
        recentWPEImports: [WPEHistoryEntry] = []
    ) {
        self.globalPauseOnBattery = globalPauseOnBattery
        self.preservePlaybackOnLock = preservePlaybackOnLock
        self.startOnLogin = startOnLogin
        self.minimumBatteryLevel = minimumBatteryLevel
        self.defaultFrameRateLimit = defaultFrameRateLimit
        self.pauseOnFullScreen = pauseOnFullScreen
        self.showInDock = showInDock
        self.weatherLocation = weatherLocation
        self.globalShortcuts = globalShortcuts
        self.recentWPEImports = recentWPEImports
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        globalPauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .globalPauseOnBattery) ?? false
        preservePlaybackOnLock = try c.decodeIfPresent(Bool.self, forKey: .preservePlaybackOnLock) ?? false
        startOnLogin = try c.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? false
        minimumBatteryLevel = try c.decodeIfPresent(Double.self, forKey: .minimumBatteryLevel)
        defaultFrameRateLimit = try c.decodeIfPresent(FrameRateLimit.self, forKey: .defaultFrameRateLimit) ?? .fps60
        pauseOnFullScreen = try c.decodeIfPresent(Bool.self, forKey: .pauseOnFullScreen) ?? true
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        weatherLocation = (try? c.decodeIfPresent(WeatherLocationPreference.self, forKey: .weatherLocation)) ?? .default
        globalShortcuts = (try? c.decodeIfPresent([GlobalShortcutAction.RawAction: GlobalShortcutBinding?].self, forKey: .globalShortcuts)) ?? [:]
        // Lossy decode: a malformed WPE history entry should not invalidate the
        // entire settings blob. Falls back to empty array if any entry breaks.
        recentWPEImports = (try? c.decodeIfPresent([WPEHistoryEntry].self, forKey: .recentWPEImports)) ?? []
        // Legacy `batteryResolutionCap` key is silently ignored on decode — superseded
        // by the "pause on battery = static wallpaper" model; no frame-rate or resolution
        // degradation is applied anymore.
    }
}
