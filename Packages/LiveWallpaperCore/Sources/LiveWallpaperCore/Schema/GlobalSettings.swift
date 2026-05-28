import Foundation

public struct GlobalSettings: Codable, Sendable {
    public var globalPauseOnBattery: Bool
    public var preservePlaybackOnLock: Bool
    public var startOnLogin: Bool
    public var minimumBatteryLevel: Double?
    public var pauseOnFullScreen: Bool
    /// Auto-pause when the foreground app looks like a game (matches a known
    /// launcher bundle id, or macOS is in Low Power Mode). Lets the user
    /// reclaim full GPU during gameplay without manually disabling the
    /// wallpaper. Default `true` is the common case; users with multi-monitor
    /// setups where the game runs on a secondary display can opt out.
    public var pauseInGameMode: Bool
    /// When true, the app activation policy is `.regular` so the app shows
    /// in the Dock and Cmd+Tab list. When false (default), the app remains
    /// `.accessory` (menu-bar only). Toggled live; no relaunch required.
    public var showInDock: Bool
    /// User preferences for the weather location pipeline. See
    /// `WeatherLocationPreference` for the full source-resolution chain.
    public var weatherLocation: WeatherLocationPreference
    /// Master switch for the global hot-key surface. When false,
    /// `GlobalShortcutManager` unregisters every Carbon hot key and refuses
    /// to re-register, but the per-action `globalShortcuts` bindings stay
    /// persisted so flipping the switch back on restores the user's
    /// previous combinations without re-asking. Default `true` preserves
    /// pre-existing behavior for installs that predate this flag.
    public var globalShortcutsEnabled: Bool = true

    /// User-customised global keyboard shortcuts. `nil` value means the
    /// shortcut is unbound; missing key means default binding still applies.
    public var globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?]
    /// LRU of recently imported Wallpaper Engine projects (capped at 20 by
    /// `SettingsManager.recordWPEImport(_:)`). Most recent at index 0.
    public var recentWPEImports: [WPEHistoryEntry] = []
    /// Per-screen cap on how much RAM the video pipeline may pin to keep a
    /// short looped clip resident (and avoid `~4 MB/s` continuous disk reads
    /// at playback bitrate). 0 disables caching entirely. The total RAM
    /// impact scales with the number of active screens: each screen
    /// independently checks its own file against this budget.
    public var videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes

    /// Pro-only runtime opt-in that surfaces the Developer Tools sidebar
    /// entry and enables `WKWebView.isInspectable` on every HTML wallpaper.
    /// Persisted so the choice survives relaunch; default `false` keeps the
    /// diagnostic surface invisible to ordinary users.
    public var developerModeEnabled: Bool = false

    /// 150 MB default — covers a typical 30s 1080p clip outright and a 30s
    /// low-bitrate 4K with margin, while keeping the visible memory
    /// footprint under ~200 MB per screen so users glancing at Activity
    /// Monitor don't see a "壁纸 用了 600 MB" surprise. Users with high
    /// bitrate 4K@60 short clips (~150 MB+) can bump this in General
    /// Settings without recompiling.
    public static let defaultVideoCacheBytes: Int = 150 * 1024 * 1024

    /// Hard ceiling exposed by the settings slider. Above this we'd be
    /// either accepting RAM pressure on smaller Macs or quietly enabling
    /// scenarios the auto-policy was meant to filter out.
    public static let maxVideoCacheBytes: Int = 1024 * 1024 * 1024

    /// Normalises any user-supplied or persisted budget into the valid
    /// range. Negative values fall back to the default; positive values
    /// are clamped at the hard ceiling. `0` is preserved — it's the
    /// documented opt-out for in-memory caching.
    public static func clampedVideoCacheBytes(_ value: Int) -> Int {
        if value < 0 { return defaultVideoCacheBytes }
        return min(value, maxVideoCacheBytes)
    }

    public init(
        // Default `false` so a freshly-installed or reset app plays its
        // wallpaper out of the box even when running on battery — power
        // savers can opt in via General Settings.
        globalPauseOnBattery: Bool = false,
        preservePlaybackOnLock: Bool = false,
        startOnLogin: Bool = false,
        minimumBatteryLevel: Double? = nil,
        pauseOnFullScreen: Bool = true,
        pauseInGameMode: Bool = true,
        showInDock: Bool = false,
        weatherLocation: WeatherLocationPreference = .default,
        globalShortcutsEnabled: Bool = true,
        globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?] = [:],
        recentWPEImports: [WPEHistoryEntry] = [],
        videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes,
        developerModeEnabled: Bool = false
    ) {
        self.globalPauseOnBattery = globalPauseOnBattery
        self.preservePlaybackOnLock = preservePlaybackOnLock
        self.startOnLogin = startOnLogin
        self.minimumBatteryLevel = minimumBatteryLevel
        self.pauseOnFullScreen = pauseOnFullScreen
        self.pauseInGameMode = pauseInGameMode
        self.showInDock = showInDock
        self.weatherLocation = weatherLocation
        self.globalShortcutsEnabled = globalShortcutsEnabled
        self.globalShortcuts = globalShortcuts
        self.recentWPEImports = recentWPEImports
        self.videoCacheMaxBytesPerScreen = Self.clampedVideoCacheBytes(videoCacheMaxBytesPerScreen)
        self.developerModeEnabled = developerModeEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        globalPauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .globalPauseOnBattery) ?? false
        preservePlaybackOnLock = try c.decodeIfPresent(Bool.self, forKey: .preservePlaybackOnLock) ?? false
        startOnLogin = try c.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? false
        minimumBatteryLevel = try c.decodeIfPresent(Double.self, forKey: .minimumBatteryLevel)
        pauseOnFullScreen = try c.decodeIfPresent(Bool.self, forKey: .pauseOnFullScreen) ?? true
        // Existing installs never saw this key — default to true so the
        // behavior matches the original hardcoded GameMode pause.
        pauseInGameMode = (try? c.decodeIfPresent(Bool.self, forKey: .pauseInGameMode)) ?? true
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        weatherLocation = (try? c.decodeIfPresent(WeatherLocationPreference.self, forKey: .weatherLocation)) ?? .default
        globalShortcutsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .globalShortcutsEnabled)) ?? true
        globalShortcuts = (try? c.decodeIfPresent([GlobalShortcutAction.RawAction: GlobalShortcutBinding?].self, forKey: .globalShortcuts)) ?? [:]
        recentWPEImports = (try? c.decodeIfPresent([WPEHistoryEntry].self, forKey: .recentWPEImports)) ?? []
        let storedCache = (try? c.decodeIfPresent(Int.self, forKey: .videoCacheMaxBytesPerScreen)) ?? GlobalSettings.defaultVideoCacheBytes
        videoCacheMaxBytesPerScreen = GlobalSettings.clampedVideoCacheBytes(storedCache)
        developerModeEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .developerModeEnabled)) ?? false
    }
}
