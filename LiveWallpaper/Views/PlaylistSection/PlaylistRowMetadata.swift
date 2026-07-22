import Foundation
import CoreGraphics

/// Async-loaded media metadata for a playlist row. All fields are populated by
/// the same async load, so the row's subtitle is empty until it completes.
struct PlaylistRowMetadata: Equatable, Sendable {
    var resolution: CGSize?
    var duration: TimeInterval?
    var folder: String?

    static let empty = PlaylistRowMetadata(resolution: nil, duration: nil, folder: nil)

    /// Apple Music-style, e.g. `1080p · 0:30 · Wallpapers`. Missing or
    /// empty-formatted fields are omitted so separators stay tight.
    var subtitle: String {
        var parts: [String] = []
        if let resolution {
            let formatted = Self.formatResolution(resolution)
            if !formatted.isEmpty { parts.append(formatted) }
        }
        if let duration {
            let formatted = Self.formatDuration(duration)
            if !formatted.isEmpty { parts.append(formatted) }
        }
        if let folder, !folder.isEmpty { parts.append(folder) }
        return parts.joined(separator: " · ")
    }

    private static func formatResolution(_ size: CGSize) -> String {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        let shortSide = min(w, h)
        switch shortSide {
        case 4320...: return "8K"
        case 2160..<4320: return "4K"
        case 1440..<2160: return "1440p"
        case 1080..<1440: return "1080p"
        case 720..<1080: return "720p"
        case 480..<720: return "480p"
        default:
            return "\(w)×\(h)"
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
