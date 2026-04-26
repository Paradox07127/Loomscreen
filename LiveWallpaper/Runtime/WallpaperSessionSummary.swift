import Foundation

enum WallpaperSessionActivity: Equatable {
    case inactive
    case active
    case paused
}

struct WallpaperSessionSummary: Equatable {
    let wallpaperType: WallpaperType?
    let activity: WallpaperSessionActivity
    let supportsPlaybackControl: Bool
    let subtitle: String?

    static let notConfigured = WallpaperSessionSummary(
        wallpaperType: nil,
        activity: .inactive,
        supportsPlaybackControl: false,
        subtitle: nil
    )

    var isConfigured: Bool {
        wallpaperType != nil && activity != .inactive
    }
}

enum WallpaperOverviewStatus: Equatable {
    case notConfigured
    case active
    case paused
}

enum WallpaperStatusAggregator {
    static func overview(for summaries: [WallpaperSessionSummary]) -> WallpaperOverviewStatus {
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
