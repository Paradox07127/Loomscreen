import Foundation
import Observation

/// Single source of truth for the user's saved wallpaper shortcuts.
@MainActor
@Observable
final class BookmarkStore {
    static let shared = BookmarkStore()

    private(set) var bookmarks: [WallpaperBookmark]

    init() {
        self.bookmarks = SettingsManager.shared.loadWallpaperBookmarks()
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
        SettingsManager.shared.saveWallpaperBookmarks(bookmarks)
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
