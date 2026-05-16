import Foundation

public enum WallpaperSessionActivity: Equatable, Sendable {
    case inactive
    case active
    case paused
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
}

public enum WallpaperStatusAggregator {
    public static func overview(for summaries: [WallpaperSessionSummary]) -> WallpaperOverviewStatus {
        let configured = summaries.filter(\.isConfigured)
        guard !configured.isEmpty else {
            return .notConfigured
        }

        if configured.contains(where: { $0.activity == .active }) {
            return .active
        }

        return .paused
    }
}
