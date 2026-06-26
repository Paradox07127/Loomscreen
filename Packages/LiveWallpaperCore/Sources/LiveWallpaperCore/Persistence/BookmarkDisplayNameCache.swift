import Foundation
import Observation

/// Caches resolved display names for security-scoped bookmarks so the UI can
/// render `bookmarkDisplayName(for:)` lookups synchronously before the
/// security-scoped URL is resolved. `@Observable` so SwiftUI views re-render
/// when a new entry lands — these dictionaries previously lived on
/// `@Observable ScreenManager`, and we preserve that invalidation flow here.
@MainActor
@Observable
public final class BookmarkDisplayNameCache {
    private var names: [Data: String] = [:]

    @ObservationIgnored private var unresolved: Set<Data> = []

    public init() {}

    public func name(for bookmarkData: Data) -> String? {
        names[bookmarkData]
    }

    /// A nil/empty `name` clears the entry and marks the bookmark unresolved.
    public func record(_ bookmarkData: Data, name: String?) {
        guard !bookmarkData.isEmpty else { return }
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            names.removeValue(forKey: bookmarkData)
            unresolved.insert(bookmarkData)
            return
        }
        names[bookmarkData] = trimmed
        unresolved.remove(bookmarkData)
    }

    public func resolveIfNeeded(_ bookmarkData: Data) {
        guard !bookmarkData.isEmpty,
              names[bookmarkData] == nil,
              !unresolved.contains(bookmarkData) else { return }
        record(bookmarkData, name: ResourceUtilities.resolveBookmarkName(bookmarkData))
    }

    public func prime(bookmarks: [Data]) {
        for bookmarkData in bookmarks {
            resolveIfNeeded(bookmarkData)
        }
    }
}
