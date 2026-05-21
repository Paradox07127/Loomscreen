import Foundation
import SwiftUI

/// Top-level automation mode chosen by the user per screen. `playlist` is
/// the default; a single-video setup is just a playlist with one entry,
/// so the legacy `.single` case has been removed.
public enum WallpaperMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case playlist
    case schedule

    public var id: String { rawValue }

    /// Tolerant decoder: configurations persisted with the rolled-back
    /// `single` mode decode to `.playlist`, which is functionally
    /// equivalent (one-entry playlist) and the new default everywhere.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = WallpaperMode(rawValue: rawValue) ?? .playlist
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var labelKey: LocalizedStringKey {
        switch self {
        case .playlist: return "Playlist"
        case .schedule: return "Schedule"
        }
    }

    public var icon: String {
        switch self {
        case .playlist: return "list.bullet.rectangle"
        case .schedule: return "clock"
        }
    }
}
