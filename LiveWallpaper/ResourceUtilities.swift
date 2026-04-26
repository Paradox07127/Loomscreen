import Foundation

@MainActor
class ResourceUtilities {
    // MARK: - Security-Scoped Bookmarks

    static func createBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: [.isReadableKey, .fileSizeKey, .contentTypeKey],
                relativeTo: nil
            )
        } catch {
            Logger.error("Failed to create bookmark: \(error.localizedDescription)", category: .fileAccess)
            return nil
        }
    }

    // MARK: - Bookmark Resolution

    /// Resolves a security-scoped bookmark to a file name.
    /// Used by ScheduleSection and PlaylistSection to display the
    /// video's last path component without duplicating the resolution
    /// boilerplate.
    static func resolveBookmarkName(_ data: Data) -> String? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url.lastPathComponent
    }
}
