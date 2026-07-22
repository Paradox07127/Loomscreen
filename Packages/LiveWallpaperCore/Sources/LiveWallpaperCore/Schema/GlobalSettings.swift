import Foundation

public struct GlobalSettings: Codable, Sendable {
    public var globalPauseOnBattery: Bool
    public var preservePlaybackOnLock: Bool
    public var startOnLogin: Bool
    public var pauseOnFullScreen: Bool
    /// Pauses playback for foreground games or Low Power Mode unless the user opts out.
    public var pauseInGameMode: Bool
    /// Pauses playback when the union of non-system windows covers at least 85% of a display.
    public var pauseOnWindowOcclusion: Bool
    /// `true` → `.regular` activation policy (Dock + Cmd+Tab); `false`
    /// (default) → `.accessory` (menu-bar only). Toggled live; no relaunch.
    public var showInDock: Bool
    public var weatherLocation: WeatherLocationPreference
    /// Enables global hot keys without discarding persisted per-action bindings when disabled.
    public var globalShortcutsEnabled: Bool = true

    /// `nil` value = shortcut unbound; missing key = default binding applies.
    public var globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?]
    /// LRU of recently imported Wallpaper Engine projects (capped at 20 by
    /// `SettingsManager.recordWPEImport(_:)`). Most recent at index 0.
    public var recentWPEImports: [WPEHistoryEntry] = []
    /// Workshop IDs excluded from automatic re-import after explicit deletion.
    public var deletedWorkshopIDs: [String] = []
    /// Per-app "pause the wallpaper while this app is in use" rules. Empty by
    /// default; evaluated event-driven off NSWorkspace activation/launch/quit
    /// notifications, so it adds no idle cost.
    public var applicationPerformanceRules: [ApplicationPerformanceRule] = []
    /// Per-screen memory cap for resident video data; zero disables caching.
    public var videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes

    /// Baseline playback values used for newly-created display configurations
    /// and explicit per-display resets. Editing these defaults does not mutate
    /// any currently-running display configuration.
    public var displayDefaults: DisplayDefaults = DisplayDefaults()

    /// Defaults developer tools on for debug builds and off for release builds.
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

    /// Explicit opt-in for TCC-gated system-audio capture used by audio-reactive Pro wallpapers.
    public var audioResponseEnabled: Bool = false

    /// Opt-in frame-rate reduction for covered displays and battery playback.
    public var adaptiveFrameRateEnabled: Bool = false

    /// Default per-screen cache budget sized for typical short 1080p and low-bitrate 4K clips.
    public static let defaultVideoCacheBytes: Int = 150 * 1024 * 1024

    /// Hard ceiling exposed by the settings slider. Above this we'd be
    /// either accepting RAM pressure on smaller Macs or quietly enabling
    /// scenarios the auto-policy was meant to filter out.
    public static let maxVideoCacheBytes: Int = 1024 * 1024 * 1024

    /// Normalizes persisted cache budgets, preserving zero as the caching opt-out.
    public static func clampedVideoCacheBytes(_ value: Int) -> Int {
        if value < 0 { return defaultVideoCacheBytes }
        return min(value, maxVideoCacheBytes)
    }

    public init(
        globalPauseOnBattery: Bool = false,
        preservePlaybackOnLock: Bool = false,
        startOnLogin: Bool = false,
        pauseOnFullScreen: Bool = true,
        pauseInGameMode: Bool = true,
        pauseOnWindowOcclusion: Bool = true,
        showInDock: Bool = false,
        weatherLocation: WeatherLocationPreference = .default,
        globalShortcutsEnabled: Bool = true,
        globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?] = [:],
        recentWPEImports: [WPEHistoryEntry] = [],
        deletedWorkshopIDs: [String] = [],
        applicationPerformanceRules: [ApplicationPerformanceRule] = [],
        videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes,
        displayDefaults: DisplayDefaults = DisplayDefaults(),
        developerModeEnabled: Bool = GlobalSettings.defaultDeveloperModeEnabled,
        audioResponseEnabled: Bool = false,
        adaptiveFrameRateEnabled: Bool = false
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
        self.displayDefaults = displayDefaults
        self.developerModeEnabled = developerModeEnabled
        self.audioResponseEnabled = audioResponseEnabled
        self.adaptiveFrameRateEnabled = adaptiveFrameRateEnabled
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
        // Default true (power-saving) for installs that predate the key; an
        // explicit stored false still wins because the field is always encoded.
        pauseOnWindowOcclusion = (try? c.decodeIfPresent(Bool.self, forKey: .pauseOnWindowOcclusion)) ?? true
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        weatherLocation = (try? c.decodeIfPresent(WeatherLocationPreference.self, forKey: .weatherLocation)) ?? .default
        globalShortcutsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .globalShortcutsEnabled)) ?? true
        globalShortcuts = (try? c.decodeIfPresent([GlobalShortcutAction.RawAction: GlobalShortcutBinding?].self, forKey: .globalShortcuts)) ?? [:]
        // Lossy per-element decode: a single history row broken by a future
        // WPEHistoryEntry shape change drops only that row, not the whole list.
        recentWPEImports = Self.decodeLossyArray(WPEHistoryEntry.self, from: c, forKey: .recentWPEImports)
        deletedWorkshopIDs = (try? c.decodeIfPresent([String].self, forKey: .deletedWorkshopIDs)) ?? []
        applicationPerformanceRules = (try? c.decodeIfPresent([ApplicationPerformanceRule].self, forKey: .applicationPerformanceRules)) ?? []
        let storedCache = (try? c.decodeIfPresent(Int.self, forKey: .videoCacheMaxBytesPerScreen)) ?? GlobalSettings.defaultVideoCacheBytes
        videoCacheMaxBytesPerScreen = GlobalSettings.clampedVideoCacheBytes(storedCache)
        displayDefaults = (try? c.decodeIfPresent(DisplayDefaults.self, forKey: .displayDefaults)) ?? DisplayDefaults()
        developerModeEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .developerModeEnabled)) ?? GlobalSettings.defaultDeveloperModeEnabled
        audioResponseEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .audioResponseEnabled)) ?? false
        adaptiveFrameRateEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .adaptiveFrameRateEnabled)) ?? false
    }

    /// Decodes an array while skipping malformed elements; absent or non-array values yield an empty result.
    private static func decodeLossyArray<Element: Decodable, Key: CodingKey>(
        _ type: Element.Type,
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [Element] {
        guard var unkeyed = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [Element] = []
        if let count = unkeyed.count { result.reserveCapacity(count) }
        while !unkeyed.isAtEnd {
            let indexBefore = unkeyed.currentIndex
            if let element = try? unkeyed.decode(Element.self) {
                result.append(element)
            } else {
                // Consume the malformed element so the cursor advances past it.
                _ = try? unkeyed.decode(AnyDecodableSkip.self)
            }
            // Safety net: if neither decode advanced the cursor, bail rather
            // than spin forever on a decoder that won't consume the element.
            if unkeyed.currentIndex == indexBefore { break }
        }
        return result
    }
}

/// Consumes one arbitrary JSON value so a lossy unkeyed decoder can advance after an element failure.
private struct AnyDecodableSkip: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}
