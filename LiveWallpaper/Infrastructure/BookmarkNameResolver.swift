import Foundation

enum BookmarkNameResolver {
    static func lastPathComponent(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        return try? ResourceUtilities.resolveBookmark(data).url.lastPathComponent
    }
}
