import Foundation
import Observation

/// Caches resolved display names for security-scoped bookmarks so the UI can
/// render `bookmarkDisplayName(for:)` lookups synchronously even before the
/// security-scoped URL is resolved. Marked `@Observable` so SwiftUI views
/// reading bookmark names through `ScreenManager.bookmarkDisplayName(for:)`
/// re-render when a new entry lands — the originating dictionaries lived on
/// `@Observable ScreenManager` and we preserve that invalidation flow here.
///
/// State:
///   - `names`: observed map of bookmark data → resolved last-path-component.
///   - `unresolved`: internal dedup set for bookmarks we've tried and failed
///     to resolve. Marked `@ObservationIgnored` because no UI reads it; it
///     just prevents `resolveIfNeeded(_:)` from re-walking the same failed
///     bookmark on every call.
@MainActor
@Observable
final class BookmarkDisplayNameCache {
    private var names: [Data: String] = [:]

    @ObservationIgnored private var unresolved: Set<Data> = []

    func name(for bookmarkData: Data) -> String? {
        names[bookmarkData]
    }

    /// Records (or clears) the display name for a bookmark. Pass `nil` /
    /// whitespace to mark the bookmark as unresolved (drop the entry and
    /// avoid re-resolving via `resolveIfNeeded(_:)`).
    func record(_ bookmarkData: Data, name: String?) {
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

    /// Best-effort resolution via `ResourceUtilities`: only walks the
    /// security-scoped URL when the bookmark is non-empty, not already
    /// cached, and not already tried-and-failed. Multiple calls with the
    /// same data are idempotent.
    func resolveIfNeeded(_ bookmarkData: Data) {
        guard !bookmarkData.isEmpty,
              names[bookmarkData] == nil,
              !unresolved.contains(bookmarkData) else { return }
        record(bookmarkData, name: ResourceUtilities.resolveBookmarkName(bookmarkData))
    }

    /// Bulk-prime helper: resolves a batch of bookmarks in one pass. Callers
    /// gather the bookmark `Data` values from `ScreenConfiguration` (active +
    /// saved + playlist + schedule) and hand them here.
    func prime(bookmarks: [Data]) {
        for bookmarkData in bookmarks {
            resolveIfNeeded(bookmarkData)
        }
    }
}
