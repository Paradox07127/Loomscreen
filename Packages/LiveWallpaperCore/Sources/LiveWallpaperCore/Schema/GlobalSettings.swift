import Foundation

/// Layout density for the MenuBar dropdown. Comfortable mirrors macOS system
/// menus (default); Compact tightens padding + drops one type step so users
/// on multi-display setups see more without scrolling.
public enum MenuBarDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact:     return "Compact"
        }
    }
}

public struct GlobalSettings: Codable, Sendable {
    public var globalPauseOnBattery: Bool
    public var preservePlaybackOnLock: Bool
    public var startOnLogin: Bool
    public var minimumBatteryLevel: Double?
    public var defaultFrameRateLimit: FrameRateLimit
    public var pauseOnFullScreen: Bool
    /// When true, the app activation policy is `.regular` so the app shows
    /// in the Dock and Cmd+Tab list. When false (default), the app remains
    /// `.accessory` (menu-bar only). Toggled live; no relaunch required.
    public var showInDock: Bool
    /// User preferences for the weather location pipeline. See
    /// `WeatherLocationPreference` for the full source-resolution chain.
    public var weatherLocation: WeatherLocationPreference
    /// User-customised global keyboard shortcuts. `nil` value means the
    /// shortcut is unbound; missing key means default binding still applies.
    public var globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?]
    /// LRU of recently imported Wallpaper Engine projects (capped at 20 by
    /// `SettingsManager.recordWPEImport(_:)`). Most recent at index 0.
    public var recentWPEImports: [WPEHistoryEntry] = []
    /// Density preference for the MenuBar dropdown. Defaults to comfortable
    /// (current behaviour); compact tightens padding for users on busy
    /// multi-display setups.
    public var menuBarDensity: MenuBarDensity = .comfortable
    /// Per-screen cap on how much RAM the video pipeline may pin to keep a
    /// short looped clip resident (and avoid `~4 MB/s` continuous disk reads
    /// at playback bitrate). 0 disables caching entirely. The total RAM
    /// impact scales with the number of active screens: each screen
    /// independently checks its own file against this budget.
    public var videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes

    /// 150 MB default — covers a typical 30s 1080p clip outright and a 30s
    /// low-bitrate 4K with margin, while keeping the visible memory
    /// footprint under ~200 MB per screen so users glancing at Activity
    /// Monitor don't see a "壁纸 用了 600 MB" surprise.
    public static let defaultVideoCacheBytes: Int = 150 * 1024 * 1024

    /// Hard ceiling exposed by the settings slider. Above this we'd be
    /// either accepting RAM pressure on smaller Macs or quietly enabling
    /// scenarios the auto-policy was meant to filter out.
    public static let maxVideoCacheBytes: Int = 1024 * 1024 * 1024

    public init(
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
        recentWPEImports: [WPEHistoryEntry] = [],
        menuBarDensity: MenuBarDensity = .comfortable,
        videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes
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
        self.menuBarDensity = menuBarDensity
        self.videoCacheMaxBytesPerScreen = videoCacheMaxBytesPerScreen
    }

    public init(from decoder: Decoder) throws {
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
        menuBarDensity = (try? c.decodeIfPresent(MenuBarDensity.self, forKey: .menuBarDensity)) ?? .comfortable
        // Clamp on decode so an old settings blob carrying a value outside
        // the current slider range can't sneak in (e.g. 5 GB). Negative
        // values fall back to default — anything bigger gets capped.
        let storedCache = (try? c.decodeIfPresent(Int.self, forKey: .videoCacheMaxBytesPerScreen)) ?? GlobalSettings.defaultVideoCacheBytes
        if storedCache < 0 {
            videoCacheMaxBytesPerScreen = GlobalSettings.defaultVideoCacheBytes
        } else {
            videoCacheMaxBytesPerScreen = min(storedCache, GlobalSettings.maxVideoCacheBytes)
        }
        // Legacy `batteryResolutionCap` key is silently ignored on decode — superseded
        // by the "pause on battery = static wallpaper" model; no frame-rate or resolution
        // degradation is applied anymore.
    }
}
