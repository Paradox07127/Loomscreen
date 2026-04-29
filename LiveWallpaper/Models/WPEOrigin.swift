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
    /// Path under the WPE cache root, e.g. `wpe-cache/3351072238`.
    /// Nil for source-folder-backed web imports and unsupported types.
    var cacheRelativePath: String?
    /// Preview filename inside the source folder (preview.gif / .jpg / .png).
    let previewFileName: String?
    /// Entry file from `project.json` (`video.mp4`, `index.html`, `scene.json`, ...).
    let entryFile: String?
    /// Explicit runtime backing. Avoids overloading `cacheRelativePath == nil`.
    let resourceLocation: WPEResourceLocation

    init(
        workshopID: String,
        title: String,
        originalType: WPEType,
        sourceFolderBookmark: Data,
        cacheRelativePath: String?,
        previewFileName: String?,
        entryFile: String? = nil,
        resourceLocation: WPEResourceLocation? = nil
    ) {
        self.workshopID = workshopID
        self.title = title
        self.originalType = originalType
        self.sourceFolderBookmark = sourceFolderBookmark
        self.cacheRelativePath = cacheRelativePath
        self.previewFileName = previewFileName
        self.entryFile = entryFile
        self.resourceLocation = resourceLocation ?? Self.defaultResourceLocation(
            originalType: originalType,
            cacheRelativePath: cacheRelativePath
        )
    }

    private enum CodingKeys: String, CodingKey {
        case workshopID
        case title
        case originalType
        case sourceFolderBookmark
        case cacheRelativePath
        case previewFileName
        case entryFile
        case resourceLocation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workshopID = try container.decode(String.self, forKey: .workshopID)
        title = try container.decode(String.self, forKey: .title)
        originalType = try container.decode(WPEType.self, forKey: .originalType)
        sourceFolderBookmark = try container.decode(Data.self, forKey: .sourceFolderBookmark)
        cacheRelativePath = try container.decodeIfPresent(String.self, forKey: .cacheRelativePath)
        previewFileName = try container.decodeIfPresent(String.self, forKey: .previewFileName)
        entryFile = try container.decodeIfPresent(String.self, forKey: .entryFile)
        resourceLocation = try container.decodeIfPresent(WPEResourceLocation.self, forKey: .resourceLocation)
            ?? Self.defaultResourceLocation(originalType: originalType, cacheRelativePath: cacheRelativePath)
    }

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
    /// points at this origin's WPE backing location. Used by ScreenManager
    /// to clear `wpeOrigin` when the user replaces the wallpaper with
    /// non-WPE content via the standard Video / HTML pickers.
    static func matchesBookmark(_ bookmarkData: Data, origin: WPEOrigin) -> Bool {
        switch origin.resourceLocation {
        case .cache:
            return matchesCacheBookmark(bookmarkData, origin: origin)
        case .sourceFolder:
            return matchesSourceFolderBookmark(bookmarkData, origin: origin)
        case .unsupported:
            return false
        }
    }

    private static func matchesCacheBookmark(_ bookmarkData: Data, origin: WPEOrigin) -> Bool {
        guard let cacheRel = origin.cacheRelativePath,
              isSafeCacheRelativePath(cacheRel) else {
            return false
        }
        guard let resolved = resolveBookmark(bookmarkData) else { return false }

        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return false }

        let rootURL = appSupport
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .standardizedFileURL
        let expectedURL = rootURL
            .appendingPathComponent(cacheRel)
            .standardizedFileURL
        // Defense-in-depth: reject persisted paths that escape root after
        // standardization, even if they passed the textual safety check.
        guard expectedURL.path == rootURL.path
                || expectedURL.path.hasPrefix(rootURL.path + "/") else {
            return false
        }
        let resolvedPath = resolved.standardizedFileURL.path
        let expectedPath = expectedURL.path
        return resolvedPath == expectedPath || resolvedPath.hasPrefix(expectedPath + "/")
    }

    private static func isSafeCacheRelativePath(_ path: String) -> Bool {
        path.hasPrefix("wpe-cache/")
            && !path.contains("\\")
            && !path.contains("..")
            && !path.contains("//")
    }

    private static func matchesSourceFolderBookmark(_ bookmarkData: Data, origin: WPEOrigin) -> Bool {
        guard let resolved = resolveBookmark(bookmarkData),
              let source = resolveBookmark(origin.sourceFolderBookmark) else {
            return false
        }
        let resolvedPath = resolved.standardizedFileURL.resolvingSymlinksInPath().path
        let sourceURL = source.standardizedFileURL.resolvingSymlinksInPath()
        let sourcePath = sourceURL.path

        // Branch by `originalType` so a sibling file inside the same WPE folder
        // does not falsely keep the badge attached. Web stays folder-anchored;
        // video must match its declared `entryFile` exactly.
        switch origin.originalType {
        case .video:
            guard let entryFile = origin.entryFile, !entryFile.isEmpty else { return false }
            let expected = sourceURL
                .appendingPathComponent(entryFile)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            return resolvedPath == expected
        case .web:
            return resolvedPath == sourcePath
        case .scene, .application, .unknown:
            return false
        }
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private static func defaultResourceLocation(
        originalType: WPEType,
        cacheRelativePath: String?
    ) -> WPEResourceLocation {
        if let cacheRelativePath, !cacheRelativePath.isEmpty {
            return .cache
        }
        if originalType == .web {
            return .sourceFolder
        }
        return .unsupported
    }
}

/// Runtime backing for a Wallpaper Engine import.
enum WPEResourceLocation: String, Codable, Equatable, Sendable {
    case cache
    case sourceFolder
    case unsupported
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
