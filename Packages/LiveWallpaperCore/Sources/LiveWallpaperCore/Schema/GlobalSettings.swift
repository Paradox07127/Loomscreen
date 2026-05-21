import Foundation

/// User preference influencing how AVPlayer treats the active video stream.
///
/// AVFoundation does not expose a public API to force software vs. hardware
/// decoding — it always tries hardware first. What we CAN control is how
/// aggressively the player loads and how much resolution it commits to,
/// which maps to a meaningful tradeoff: battery / RAM / GPU vs. fidelity.
public enum VideoDecoderPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Leave `AVPlayerItem` defaults untouched — let AVFoundation pick.
    /// Matches behavior before this preference existed.
    case auto
    /// Caps `preferredMaximumResolution` at 1080p and `preferredPeakBitRate`
    /// at 8 Mbps. Visibly the same on a single display for most clips;
    /// drastically reduces sustained GPU load on multi-screen 4K setups.
    case batterySaver
    /// Removes resolution and bitrate caps so 4K HDR content plays at native
    /// fidelity. On Intel Macs or older iGPUs this can drop the frame rate
    /// of OTHER on-screen apps; opt-in.
    case highQuality

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .auto:         return "Auto"
        case .batterySaver: return "Battery Saver"
        case .highQuality:  return "High Quality"
        }
    }

    public var descriptionKey: String {
        switch self {
        case .auto:
            return "macOS picks resolution and bitrate caps based on power source."
        case .batterySaver:
            return "Caps playback at 1080p / 8 Mbps. Looks identical on a 1080p display; lower GPU draw, longer battery life."
        case .highQuality:
            return "Removes resolution and bitrate caps. May reduce frame rate of other apps on Intel Macs and older iGPUs."
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
    /// Per-screen cap on how much RAM the video pipeline may pin to keep a
    /// short looped clip resident (and avoid `~4 MB/s` continuous disk reads
    /// at playback bitrate). 0 disables caching entirely. The total RAM
    /// impact scales with the number of active screens: each screen
    /// independently checks its own file against this budget.
    public var videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes

    /// Decoder load preference applied to every AVPlayer-backed video
    /// wallpaper. See `VideoDecoderPreference` for the semantics.
    public var videoDecoderPreference: VideoDecoderPreference = .auto

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
        defaultFrameRateLimit: FrameRateLimit = .fps60,
        pauseOnFullScreen: Bool = true,
        showInDock: Bool = false,
        weatherLocation: WeatherLocationPreference = .default,
        globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?] = [:],
        recentWPEImports: [WPEHistoryEntry] = [],
        videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes,
        videoDecoderPreference: VideoDecoderPreference = .auto
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
        self.videoCacheMaxBytesPerScreen = Self.clampedVideoCacheBytes(videoCacheMaxBytesPerScreen)
        self.videoDecoderPreference = videoDecoderPreference
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
        recentWPEImports = (try? c.decodeIfPresent([WPEHistoryEntry].self, forKey: .recentWPEImports)) ?? []
        let storedCache = (try? c.decodeIfPresent(Int.self, forKey: .videoCacheMaxBytesPerScreen)) ?? GlobalSettings.defaultVideoCacheBytes
        videoCacheMaxBytesPerScreen = GlobalSettings.clampedVideoCacheBytes(storedCache)
        videoDecoderPreference = (try? c.decodeIfPresent(VideoDecoderPreference.self, forKey: .videoDecoderPreference)) ?? .auto
    }
}
