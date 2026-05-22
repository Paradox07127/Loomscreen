import Foundation

public enum WallpaperSessionActivity: Equatable, Sendable {
    /// No wallpaper assigned to this screen.
    case inactive
    /// Healthy + playing/visible.
    case active
    /// Healthy, playing engine running, but per-screen playback was paused
    /// by the user. Window is visible — last frame still on the desktop.
    case paused
    /// Master switch off — window hidden, NOTHING visible on the desktop.
    /// Distinct from `.paused` because pause keeps the last frame visible
    /// while off shows the actual desktop background through.
    case off
    /// Wallpaper failed to load (HTML 4xx/5xx, video decode error,
    /// resource missing, etc.). UI surfaces a red dot + the failure subtitle.
    case error
}

public struct WallpaperSessionSummary: Equatable, Sendable {
    public let wallpaperType: WallpaperType?
    public let activity: WallpaperSessionActivity
    public let supportsPlaybackControl: Bool
    public let subtitle: String?

    public init(
        wallpaperType: WallpaperType?,
        activity: WallpaperSessionActivity,
        supportsPlaybackControl: Bool,
        subtitle: String?
    ) {
        self.wallpaperType = wallpaperType
        self.activity = activity
        self.supportsPlaybackControl = supportsPlaybackControl
        self.subtitle = subtitle
    }

    public static let notConfigured = WallpaperSessionSummary(
        wallpaperType: nil,
        activity: .inactive,
        supportsPlaybackControl: false,
        subtitle: nil
    )

    public var isConfigured: Bool {
        wallpaperType != nil && activity != .inactive
    }
}

public enum WallpaperOverviewStatus: Equatable, Sendable {
    case notConfigured
    case active
    case paused
    case off
    case error
}

public enum WallpaperStatusAggregator {
    /// Priority: any active beats everything; if none active but any errored
    /// surface `.error`; if all configured are `.off` (master switch was
    /// flipped for every screen) report `.off`; otherwise `.paused`.
    public static func overview(for summaries: [WallpaperSessionSummary]) -> WallpaperOverviewStatus {
        let configured = summaries.filter(\.isConfigured)
        guard !configured.isEmpty else {
            return .notConfigured
        }

        if configured.contains(where: { $0.activity == .active }) {
            return .active
        }
        if configured.contains(where: { $0.activity == .error }) {
            return .error
        }
        if configured.allSatisfy({ $0.activity == .off }) {
            return .off
        }
        return .paused
    }
}
