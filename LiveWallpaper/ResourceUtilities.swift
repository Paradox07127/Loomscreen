import CryptoKit
import Foundation

@MainActor
class ResourceUtilities {
    struct BookmarkResolution {
        let url: URL
        let isStale: Bool
        let isSecurityScoped: Bool
    }

    // MARK: - Security-Scoped Bookmarks

    static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [
        .withSecurityScope,
        .securityScopeAllowOnlyReadAccess
    ]

    static func createBookmark(for url: URL) -> Data? {
        // Some URL sources need an active scope before bookmarkData can read metadata.
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let primaryOptions = bookmarkCreationOptions
        let snapshotKeys: Set<URLResourceKey> = [.isReadableKey, .fileSizeKey, .contentTypeKey]

        if let data = tryBookmark(url, options: primaryOptions, keys: snapshotKeys) {
            return data
        }
        Logger.warning(
            "Bookmark step 1 (security-scope + resource keys) failed; retrying without resource keys",
            category: .fileAccess
        )

        if let data = tryBookmark(url, options: primaryOptions, keys: nil) {
            return data
        }
        Logger.error(
            "Bookmark creation failed in both tiers for \(url.lastPathComponent); refusing to persist a non-security-scoped placeholder",
            category: .fileAccess
        )
        return nil
    }

    /// Creates a persistent video bookmark. Security-scoped bookmarks are the
    /// preferred path for user-selected files. If macOS' app-scope bookmark
    /// service fails, copy the video into our Application Support container and
    /// bookmark that app-owned copy so the selected wallpaper still survives
    /// relaunch.
    static func createVideoBookmark(
        for url: URL,
        applicationSupportRootURL: URL? = nil,
        secureBookmarkCreator: (URL) -> Data? = { createBookmark(for: $0) },
        localBookmarkCreator: (URL) -> Data? = { createLocalBookmark(for: $0) }
    ) -> Data? {
        if let secureBookmark = secureBookmarkCreator(url) {
            return secureBookmark
        }

        guard let copiedURL = copyVideoIntoApplicationSupport(
            from: url,
            applicationSupportRootURL: applicationSupportRootURL
        ) else {
            return nil
        }

        guard let localBookmark = localBookmarkCreator(copiedURL) else {
            Logger.error(
                "Failed to bookmark app-owned video copy '\(copiedURL.lastPathComponent)'",
                category: .fileAccess
            )
            return nil
        }

        Logger.info(
            "Using app-owned video copy after scoped bookmark creation failed: \(copiedURL.lastPathComponent)",
            category: .fileAccess
        )
        return localBookmark
    }

    nonisolated static func resolveBookmark(_ data: Data) throws -> BookmarkResolution {
        var scopedStale = false
        do {
            let scopedURL = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &scopedStale
            )
            return BookmarkResolution(url: scopedURL, isStale: scopedStale, isSecurityScoped: true)
        } catch {
            var plainStale = false
            let plainURL = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &plainStale
            )
            return BookmarkResolution(url: plainURL, isStale: plainStale, isSecurityScoped: false)
        }
    }

    /// Attempts one scoped bookmark write and logs the underlying NSError.
    private static func tryBookmark(
        _ url: URL,
        options: URL.BookmarkCreationOptions,
        keys: Set<URLResourceKey>?
    ) -> Data? {
        do {
            return try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: keys,
                relativeTo: nil
            )
        } catch let error as NSError {
            Logger.error(
                "createBookmark failed [domain=\(error.domain) code=\(error.code)] for '\(url.lastPathComponent)' — \(error.localizedDescription); userInfo=\(error.userInfo)",
                category: .fileAccess
            )
            return nil
        }
    }

    private static func createLocalBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch let error as NSError {
            Logger.error(
                "createLocalBookmark failed [domain=\(error.domain) code=\(error.code)] for '\(url.lastPathComponent)' — \(error.localizedDescription)",
                category: .fileAccess
            )
            return nil
        }
    }

    private static func copyVideoIntoApplicationSupport(
        from sourceURL: URL,
        applicationSupportRootURL: URL?
    ) -> URL? {
        let fileManager = FileManager.default
        let supportRoot: URL

        if let applicationSupportRootURL {
            supportRoot = applicationSupportRootURL
        } else if let resolved = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            supportRoot = resolved.appendingPathComponent("LiveWallpaper", isDirectory: true)
        } else {
            Logger.error("Unable to resolve Application Support for video import fallback", category: .fileAccess)
            return nil
        }

        let importDirectory = supportRoot
            .appendingPathComponent("ImportedVideos", isDirectory: true)
            .appendingPathComponent(importIdentifier(for: sourceURL), isDirectory: true)
        let targetName = sourceURL.lastPathComponent.isEmpty ? "video" : sourceURL.lastPathComponent
        let targetURL = importDirectory.appendingPathComponent(targetName, isDirectory: false)

        do {
            try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: targetURL.path(percentEncoded: false)),
               importedCopyMatchesSource(sourceURL, targetURL: targetURL) {
                return targetURL
            }
            if fileManager.fileExists(atPath: targetURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.copyItem(at: sourceURL, to: targetURL)
            return targetURL
        } catch let error as NSError {
            Logger.error(
                "Failed to copy video into Application Support [domain=\(error.domain) code=\(error.code)] for '\(sourceURL.lastPathComponent)' — \(error.localizedDescription)",
                category: .fileAccess
            )
            return nil
        }
    }

    private static func importIdentifier(for sourceURL: URL) -> String {
        let resourceValues = try? sourceURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let fingerprint = [
            sourceURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false),
            String(resourceValues?.fileSize ?? -1),
            String(resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? -1)
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func importedCopyMatchesSource(_ sourceURL: URL, targetURL: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        let sourceSize = try? sourceURL.resourceValues(forKeys: keys).fileSize
        let targetSize = try? targetURL.resourceValues(forKeys: keys).fileSize
        return sourceSize != nil && sourceSize == targetSize
    }

    // MARK: - Bookmark Resolution

    /// Resolves a bookmark to a display name.
    static func resolveBookmarkName(_ data: Data) -> String? {
        BookmarkNameResolver.lastPathComponent(from: data)
    }

    // MARK: - HTML Source Bookmarking

    /// Prefers a folder bookmark so sibling CSS/JS/images survive relaunch.
    static func htmlSourceFromPickedFile(_ fileURL: URL) -> HTMLSource? {
        let folderURL = fileURL.deletingLastPathComponent()
        if let folderBookmark = createBookmark(for: folderURL) {
            return .folder(bookmarkData: folderBookmark, indexFileName: fileURL.lastPathComponent)
        }
        if let fileBookmark = createBookmark(for: fileURL) {
            return .file(bookmarkData: fileBookmark)
        }
        return nil
    }

    static func inferHTMLIndexFileName(from entries: [String]) -> String {
        for standardName in ["index.html", "index.htm"] {
            if let entry = entries.first(where: { $0.lowercased() == standardName }) {
                return entry
            }
        }
        return entries.first { $0.lowercased().hasSuffix(".html") } ?? "index.html"
    }
}
