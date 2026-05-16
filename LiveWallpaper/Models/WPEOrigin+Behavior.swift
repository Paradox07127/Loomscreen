import Foundation

/// Bookmark-resolution + path-matching helpers for `WPEOrigin`.
///
/// Lives in a separate file so the schema (`WPEOrigin.swift`) stays free of
/// `WPEPathSafety` and the App Support / FileManager surface. Phase 4 moves
/// this extension into the ProWPE package; Lite must not link it.
extension WPEOrigin {
    var sourcePreviewURL: URL? {
        guard let previewFileName,
              let sourceFolder = WPEPathSafety.resolveSecurityScopedBookmark(sourceFolderBookmark) else {
            return nil
        }
        return WPEPathSafety.resourceURL(root: sourceFolder, relativePath: previewFileName)
    }

    var sourceEntryURL: URL? {
        guard let entryFile,
              let sourceFolder = WPEPathSafety.resolveSecurityScopedBookmark(sourceFolderBookmark) else {
            return nil
        }
        return WPEPathSafety.resourceURL(root: sourceFolder, relativePath: entryFile)
    }

    /// Best-effort check that a security-scoped video/folder bookmark still
    /// points at this origin's WPE backing location. Used by
    /// `WPEOriginReconciler` to clear `wpeOrigin` when the user replaces
    /// the wallpaper with non-WPE content via the standard Video / HTML
    /// pickers.
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
        // Defense-in-depth: reject persisted paths that escape root after
        // standardization, even if they passed the textual safety check.
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

        // Branch by `originalType` so a sibling file inside the same WPE folder
        // does not falsely keep the badge attached. Web stays folder-anchored;
        // video must match its declared `entryFile` exactly.
        switch origin.originalType {
        case .video:
            guard let expected = origin.sourceEntryURL else { return false }
            return resolvedPath == expected.path
        case .web:
            return resolvedPath == sourcePath
        case .scene, .application, .unknown:
            return false
        }
    }
}
