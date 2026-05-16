import Foundation
import Observation

/// Caches resolved display names for security-scoped bookmarks so the UI can
/// render `bookmarkDisplayName(for:)` lookups synchronously even before the
/// security-scoped URL is resolved. Marked `@Observable` so SwiftUI views
/// reading bookmark names through `ScreenManager.bookmarkDisplayName(for:)`
/// re-render when a new entry lands — the originating dictionaries lived on
/// `@Observable ScreenManager` and we preserve that invalidation flow here.
@MainActor
@Observable
public final class BookmarkDisplayNameCache {
    private var names: [Data: String] = [:]

    @ObservationIgnored private var unresolved: Set<Data> = []

    public init() {}

    public func name(for bookmarkData: Data) -> String? {
        names[bookmarkData]
    }

    /// Records (or clears) the display name for a bookmark.
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

    /// Best-effort resolution via `ResourceUtilities`. Idempotent.
    public func resolveIfNeeded(_ bookmarkData: Data) {
        guard !bookmarkData.isEmpty,
              names[bookmarkData] == nil,
              !unresolved.contains(bookmarkData) else { return }
        record(bookmarkData, name: ResourceUtilities.resolveBookmarkName(bookmarkData))
    }

    /// Bulk-prime helper: resolves a batch of bookmarks in one pass.
    public func prime(bookmarks: [Data]) {
        for bookmarkData in bookmarks {
            resolveIfNeeded(bookmarkData)
        }
    }
}
