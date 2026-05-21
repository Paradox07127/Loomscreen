import Foundation
import CoreGraphics

/// Async-loaded media metadata for a playlist row.
///
/// Loaded lazily by `PlaylistMetadataService` from the underlying video file.
/// The view falls back to the parent folder name as the subtitle until the
/// first real load completes — that way the row never shows an empty subtitle
/// even on cold start.
struct PlaylistRowMetadata: Equatable, Sendable {
    var resolution: CGSize?
    var duration: TimeInterval?
    /// Parent directory name — always available once the bookmark resolves.
    var folder: String?

    static let empty = PlaylistRowMetadata(resolution: nil, duration: nil, folder: nil)

    /// Subtitle composed Apple Music-style: `1080p · 0:30 · Wallpapers`.
    /// Parts collapse gracefully: any missing or empty-formatted field is
    /// omitted, separators stay tight.
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
        // Bucket on the short side so portrait clips (e.g. 1080×1920 from
        // a vertical monitor) don't get mislabelled as 1440p.
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
