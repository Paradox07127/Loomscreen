import Foundation

public struct GlobalSettings: Codable, Sendable {
    public var globalPauseOnBattery: Bool
    public var preservePlaybackOnLock: Bool
    public var startOnLogin: Bool
    public var pauseOnFullScreen: Bool
    /// Auto-pause when the foreground app declares a game
    /// `LSApplicationCategoryType` (or macOS is in Low Power Mode). Lets the
    /// user reclaim full GPU during gameplay without manually disabling the
    /// wallpaper. Default `true` is the common case; users with multi-monitor
    /// setups where the game runs on a secondary display can opt out.
    public var pauseInGameMode: Bool
    /// Auto-pause when other apps' windows blanket the desktop. Unlike
    /// `pauseOnFullScreen` (which needs a single ≥95% window), this sums the
    /// *union* area of every non-system window on a display and pauses when it
    /// covers ≥ 85% — so a desktop tiled/overlapped by ordinary windows still
    /// yields the GPU. Off by default; it's a more aggressive sibling of the
    /// full-screen rule.
    public var pauseOnWindowOcclusion: Bool
    /// `true` → `.regular` activation policy (Dock + Cmd+Tab); `false`
    /// (default) → `.accessory` (menu-bar only). Toggled live; no relaunch.
    public var showInDock: Bool
    public var weatherLocation: WeatherLocationPreference
    /// Master switch for the global hot-key surface. When false,
    /// `GlobalShortcutManager` unregisters every Carbon hot key and refuses
    /// to re-register, but the per-action `globalShortcuts` bindings stay
    /// persisted so flipping the switch back on restores the user's
    /// previous combinations without re-asking. Default `true` preserves
    /// pre-existing behavior for installs that predate this flag.
    public var globalShortcutsEnabled: Bool = true

    /// `nil` value = shortcut unbound; missing key = default binding applies.
    public var globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?]
    /// LRU of recently imported Wallpaper Engine projects (capped at 20 by
    /// `SettingsManager.recordWPEImport(_:)`). Most recent at index 0.
    public var recentWPEImports: [WPEHistoryEntry] = []
    /// Workshop IDs the user explicitly deleted. The auto-import scan
    /// (`WorkshopFolderImportCoordinator.ingestExistingDownloads`) skips these so
    /// a still-present SteamCMD download or library-folder copy doesn't silently
    /// reappear after a delete. Cleared the moment the user re-adds the item
    /// deliberately (paste / download / manual folder import) via
    /// `SettingsManager.recordWPEImport(_:)`. Capped in `SettingsManager`.
    public var deletedWorkshopIDs: [String] = []
    /// Per-app "pause the wallpaper while this app is in use" rules. Empty by
    /// default; evaluated event-driven off NSWorkspace activation/launch/quit
    /// notifications, so it adds no idle cost.
    public var applicationPerformanceRules: [ApplicationPerformanceRule] = []
    /// Per-screen cap on how much RAM the video pipeline may pin to keep a
    /// short looped clip resident (and avoid `~4 MB/s` continuous disk reads
    /// at playback bitrate). 0 disables caching entirely. The total RAM
    /// impact scales with the number of active screens: each screen
    /// independently checks its own file against this budget.
    public var videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes

    /// Default for `developerModeEnabled`: ON in DEBUG builds so the Developer
    /// Tools surface is reachable during development without a manual opt-in,
    /// OFF in Release so ordinary users never see it. An explicit, persisted
    /// user choice still wins over this default (see the decoder below).
    public static var defaultDeveloperModeEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Pro-only runtime opt-in that surfaces the Developer Tools sidebar
    /// entry and enables `WKWebView.isInspectable` on every HTML wallpaper.
    public var developerModeEnabled: Bool = GlobalSettings.defaultDeveloperModeEnabled

    /// Pro-only master switch for audio-reactive wallpapers. When true, the app
    /// captures system audio output (Core Audio process tap) so audio-reactive
    /// scenes/shaders follow whatever is playing. Default `false` — capturing
    /// system audio is privacy-sensitive and gated behind a TCC grant, so it
    /// must be an explicit opt-in, never on by default.
    public var audioResponseEnabled: Bool = false

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
        pauseOnFullScreen: Bool = true,
        pauseInGameMode: Bool = true,
        pauseOnWindowOcclusion: Bool = false,
        showInDock: Bool = false,
        weatherLocation: WeatherLocationPreference = .default,
        globalShortcutsEnabled: Bool = true,
        globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?] = [:],
        recentWPEImports: [WPEHistoryEntry] = [],
        deletedWorkshopIDs: [String] = [],
        applicationPerformanceRules: [ApplicationPerformanceRule] = [],
        videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes,
        developerModeEnabled: Bool = GlobalSettings.defaultDeveloperModeEnabled,
        audioResponseEnabled: Bool = false
    ) {
        self.globalPauseOnBattery = globalPauseOnBattery
        self.preservePlaybackOnLock = preservePlaybackOnLock
        self.startOnLogin = startOnLogin
        self.pauseOnFullScreen = pauseOnFullScreen
        self.pauseInGameMode = pauseInGameMode
        self.pauseOnWindowOcclusion = pauseOnWindowOcclusion
        self.showInDock = showInDock
        self.weatherLocation = weatherLocation
        self.globalShortcutsEnabled = globalShortcutsEnabled
        self.globalShortcuts = globalShortcuts
        self.recentWPEImports = recentWPEImports
        self.deletedWorkshopIDs = deletedWorkshopIDs
        self.applicationPerformanceRules = applicationPerformanceRules
        self.videoCacheMaxBytesPerScreen = Self.clampedVideoCacheBytes(videoCacheMaxBytesPerScreen)
        self.developerModeEnabled = developerModeEnabled
        self.audioResponseEnabled = audioResponseEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        globalPauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .globalPauseOnBattery) ?? false
        preservePlaybackOnLock = try c.decodeIfPresent(Bool.self, forKey: .preservePlaybackOnLock) ?? false
        startOnLogin = try c.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? false
        pauseOnFullScreen = try c.decodeIfPresent(Bool.self, forKey: .pauseOnFullScreen) ?? true
        // Existing installs never saw this key — default to true so the
        // behavior matches the original hardcoded GameMode pause.
        pauseInGameMode = (try? c.decodeIfPresent(Bool.self, forKey: .pauseInGameMode)) ?? true
        pauseOnWindowOcclusion = (try? c.decodeIfPresent(Bool.self, forKey: .pauseOnWindowOcclusion)) ?? false
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        weatherLocation = (try? c.decodeIfPresent(WeatherLocationPreference.self, forKey: .weatherLocation)) ?? .default
        globalShortcutsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .globalShortcutsEnabled)) ?? true
        globalShortcuts = (try? c.decodeIfPresent([GlobalShortcutAction.RawAction: GlobalShortcutBinding?].self, forKey: .globalShortcuts)) ?? [:]
        recentWPEImports = (try? c.decodeIfPresent([WPEHistoryEntry].self, forKey: .recentWPEImports)) ?? []
        deletedWorkshopIDs = (try? c.decodeIfPresent([String].self, forKey: .deletedWorkshopIDs)) ?? []
        applicationPerformanceRules = (try? c.decodeIfPresent([ApplicationPerformanceRule].self, forKey: .applicationPerformanceRules)) ?? []
        let storedCache = (try? c.decodeIfPresent(Int.self, forKey: .videoCacheMaxBytesPerScreen)) ?? GlobalSettings.defaultVideoCacheBytes
        videoCacheMaxBytesPerScreen = GlobalSettings.clampedVideoCacheBytes(storedCache)
        developerModeEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .developerModeEnabled)) ?? GlobalSettings.defaultDeveloperModeEnabled
        audioResponseEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .audioResponseEnabled)) ?? false
    }
}
