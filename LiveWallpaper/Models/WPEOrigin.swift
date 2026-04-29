import Foundation

/// Persisted Wallpaper Engine workshop origin metadata, attached to a
/// `ScreenConfiguration` to mark that the active wallpaper was imported
/// from a Steam Workshop project rather than picked directly by the user.
struct WPEOrigin: Codable, Equatable, Sendable {
    let workshopID: String
    let title: String
    /// Original WPE category (preserved even when runtime maps to .video / .html).
    let originalType: WPEType
    /// Security-scoped bookmark to the source `~/Documents/Live Wallpapers/<appid>/<wid>/` folder.
    let sourceFolderBookmark: Data
    /// Path under the WPE cache root, e.g. `wpe-cache/3351072238`. Nil for unsupported types.
    var cacheRelativePath: String?
    /// Preview filename inside the source folder (preview.gif / .jpg / .png).
    let previewFileName: String?

    var displayTypeName: String {
        switch originalType {
        case .video:        return "Video"
        case .web:          return "Web"
        case .scene:        return "Scene"
        case .application:  return "App"
        case .unknown:      return "Unknown"
        }
    }

    /// Best-effort check that a security-scoped video/folder bookmark still
    /// points inside this origin's WPE cache directory. Used by ScreenManager
    /// to clear `wpeOrigin` when the user replaces the wallpaper with
    /// non-WPE content via the standard Video / HTML pickers.
    /// Compares the bookmark's resolved path against the real WPE cache root
    /// so a user folder containing the literal string "/wpe-cache/" cannot
    /// be misclassified as WPE-originated.
    static func matchesBookmark(_ bookmarkData: Data, origin: WPEOrigin) -> Bool {
        guard let cacheRel = origin.cacheRelativePath, !cacheRel.isEmpty else {
            return false
        }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return false }

        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return false }

        let expectedURL = appSupport
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent(cacheRel)
            .standardizedFileURL
        let resolvedPath = resolved.standardizedFileURL.path
        let expectedPath = expectedURL.path
        return resolvedPath == expectedPath || resolvedPath.hasPrefix(expectedPath + "/")
    }
}

/// WPE workshop project category, decoded from `project.json`'s `type` field.
enum WPEType: String, Codable, Equatable, Sendable {
    case video
    case web
    case scene
    case application
    case unknown

    init(rawWPEValue raw: String?) {
        switch raw?.lowercased() {
        case "video":       self = .video
        case "web":         self = .web
        case "scene":       self = .scene
        case "application": self = .application
        default:            self = .unknown
        }
    }
}
