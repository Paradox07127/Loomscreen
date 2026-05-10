import Foundation

enum WPEPathSafety {
    static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("..")
    }

    static func isSafeWorkshopID(_ value: String) -> Bool {
        isSafePathComponent(value)
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("..")
            && value != "."
    }

    static func isStrictSafeRelativePath(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("\\")
            && !components.contains("..")
            && !components.contains(".")
            && !components.contains("")
    }

    static func isSafeCacheRelativePath(_ path: String) -> Bool {
        path.hasPrefix("wpe-cache/")
            && !path.contains("\\")
            && !path.contains("..")
            && !path.contains("//")
    }

    static func contains(_ child: URL, in parent: URL) -> Bool {
        let childPath = normalizedPath(child.path(percentEncoded: false))
        let parentPath = normalizedPath(parent.path(percentEncoded: false))
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    static func resourceURL(root: URL, relativePath: String) -> URL? {
        guard isSafeRelativePath(relativePath) else { return nil }
        return containedResourceURL(root: root, relativePath: relativePath)
    }

    static func strictResourceURL(root: URL, relativePath: String) -> URL? {
        guard isStrictSafeRelativePath(relativePath) else { return nil }
        return containedResourceURL(root: root, relativePath: relativePath)
    }

    private static func containedResourceURL(root: URL, relativePath: String) -> URL? {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = rootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard contains(url, in: rootURL) else { return nil }
        return url
    }

    static func resolveSecurityScopedBookmark(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    static func defaultApplicationSupportRoot(fileManager: FileManager) -> URL? {
        if let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return applicationSupport.appendingPathComponent("LiveWallpaper", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/LiveWallpaper", isDirectory: true)
    }

    private static func normalizedPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
