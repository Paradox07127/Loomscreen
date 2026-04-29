import Foundation
import Observation

/// Persistence seam — production binds to UserDefaults via SettingsManager,
/// tests inject an in-memory implementation.
@MainActor
protocol BookmarkPersisting {
    func load() -> [WallpaperBookmark]
    func save(_ bookmarks: [WallpaperBookmark])
}

@MainActor
struct SettingsManagerBookmarkPersistence: BookmarkPersisting {
    func load() -> [WallpaperBookmark] { SettingsManager.shared.loadWallpaperBookmarks() }
    func save(_ bookmarks: [WallpaperBookmark]) { SettingsManager.shared.saveWallpaperBookmarks(bookmarks) }
}

/// Single source of truth for the user's saved wallpaper shortcuts.
@MainActor
@Observable
final class BookmarkStore {
    static let shared = BookmarkStore()

    private(set) var bookmarks: [WallpaperBookmark]
    @ObservationIgnored private let persistence: any BookmarkPersisting

    init(persistence: any BookmarkPersisting = SettingsManagerBookmarkPersistence()) {
        self.persistence = persistence
        self.bookmarks = persistence.load()
    }

    /// Append a new bookmark and persist immediately.
    @discardableResult
    func add(label: String, content: WallpaperContent) -> WallpaperBookmark {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? Self.defaultLabel(for: content) : trimmed
        let bookmark = WallpaperBookmark(label: resolved, content: content)
        bookmarks.append(bookmark)
        persist()
        return bookmark
    }

    func remove(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    func resetAfterSettingsCleared() {
        bookmarks.removeAll()
    }

    func rename(_ id: UUID, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].label = trimmed
        persist()
    }

    /// True when an equivalent content is already saved (so UI can disable
    /// the "Save" button instead of producing duplicates).
    func contains(_ content: WallpaperContent) -> Bool {
        bookmarks.contains { $0.content == content }
    }

    private func persist() {
        persistence.save(bookmarks)
    }

    /// Friendly fallback label derived from the content itself.
    static func defaultLabel(for content: WallpaperContent) -> String {
        switch content {
        case .video(let bookmarkData):
            return ResourceUtilities.resolveBookmarkName(bookmarkData) ?? "Video"
        case .html(let source, _):
            return source.displayName
        case .metalShader(let preset):
            return preset.rawValue
        }
    }
}
