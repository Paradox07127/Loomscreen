import Foundation
import LiveWallpaperCore

/// Bookmark-resolution + path-matching helpers for `WPEOrigin`.
///
/// Lives in the LiveWallpaperProWPE package so the schema
/// (`LiveWallpaperCore/Schema/WPEOrigin.swift`) stays free of
/// `WPEPathSafety` and the App Support / FileManager surface. Lite must
/// not link this package; Pro receives it as part of the renderer + import
/// pipeline bundle.
extension WPEOrigin {
    public var sourcePreviewURL: URL? {
        guard let previewFileName,
              let sourceFolder = WPEPathSafety.resolveSecurityScopedBookmark(sourceFolderBookmark) else {
            return nil
        }
        return WPEPathSafety.resourceURL(root: sourceFolder, relativePath: previewFileName)
    }

    public var sourceEntryURL: URL? {
        guard let entryFile,
              let sourceFolder = WPEPathSafety.resolveSecurityScopedBookmark(sourceFolderBookmark) else {
            return nil
        }
        return WPEPathSafety.resourceURL(root: sourceFolder, relativePath: entryFile)
    }

    /// Best-effort check that a security-scoped video/folder bookmark still points at this origin's WPE backing location.
    public static func matchesBookmark(_ bookmarkData: Data, origin: WPEOrigin) -> Bool {
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
              WPEPathSafety.isSafeCacheRelativePath(cacheRel) else {
            return false
        }
        guard let resolved = WPEPathSafety.resolveSecurityScopedBookmark(bookmarkData) else { return false }

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
        guard WPEPathSafety.contains(expectedURL, in: rootURL) else {
            return false
        }
        let resolvedPath = resolved.standardizedFileURL.path
        let expectedPath = expectedURL.path
        return resolvedPath == expectedPath || resolvedPath.hasPrefix(expectedPath + "/")
    }

    private static func matchesSourceFolderBookmark(_ bookmarkData: Data, origin: WPEOrigin) -> Bool {
        guard let resolved = WPEPathSafety.resolveSecurityScopedBookmark(bookmarkData),
              let source = WPEPathSafety.resolveSecurityScopedBookmark(origin.sourceFolderBookmark) else {
            return false
        }
        let resolvedPath = resolved.standardizedFileURL.resolvingSymlinksInPath().path
        let sourceURL = source.standardizedFileURL.resolvingSymlinksInPath()
        let sourcePath = sourceURL.path

        switch origin.originalType {
        case .video:
            // Loose video: bookmark points at the entry file in the folder.
            if let expected = origin.sourceEntryURL, resolvedPath == expected.path {
                return true
            }
            // In-place packaged video: bookmark points at the source
            // `scene.pkg` (the entry is read windowed from it, not extracted).
            let packagePath = sourceURL
                .appendingPathComponent("scene.pkg")
                .standardizedFileURL
                .path
            return resolvedPath == packagePath
        case .web:
            return resolvedPath == sourcePath
        case .scene, .application, .unknown:
            return false
        }
    }
}
