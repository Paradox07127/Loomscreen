import Foundation

enum BookmarkNameResolver {
    static func lastPathComponent(from data: Data) -> String? {
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
}
