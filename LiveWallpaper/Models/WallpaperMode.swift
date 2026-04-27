import Foundation

/// Top-level automation mode chosen by the user per screen. Resolves the
/// long-standing playlist/schedule conflict by giving a single authoritative
/// source of truth for which automation, if any, is active.
enum WallpaperMode: String, Codable, CaseIterable, Identifiable {
    case single
    case playlist
    case schedule

    var id: String { rawValue }

    var label: String {
        switch self {
        case .single:   return "Single"
        case .playlist: return "Playlist"
        case .schedule: return "Schedule"
        }
    }

    var icon: String {
        switch self {
        case .single:   return "play.rectangle"
        case .playlist: return "list.bullet.rectangle"
        case .schedule: return "clock"
        }
    }
}
