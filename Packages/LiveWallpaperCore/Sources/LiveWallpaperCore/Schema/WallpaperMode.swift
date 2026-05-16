import Foundation
import SwiftUI

/// Top-level automation mode chosen by the user per screen. Resolves the
/// long-standing playlist/schedule conflict by giving a single authoritative
/// source of truth for which automation, if any, is active.
public enum WallpaperMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case single
    case playlist
    case schedule

    public var id: String { rawValue }

    public var labelKey: LocalizedStringKey {
        switch self {
        case .single:   return "Single"
        case .playlist: return "Playlist"
        case .schedule: return "Schedule"
        }
    }

    public var icon: String {
        switch self {
        case .single:   return "play.rectangle"
        case .playlist: return "list.bullet.rectangle"
        case .schedule: return "clock"
        }
    }
}
