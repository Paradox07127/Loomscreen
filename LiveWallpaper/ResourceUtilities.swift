import Foundation

@MainActor
class ResourceUtilities {
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

    // MARK: - Bookmark Resolution

    /// Resolves a bookmark to a display name.
    static func resolveBookmarkName(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url.lastPathComponent
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
