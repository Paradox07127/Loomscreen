import Foundation
import LiveWallpaperCore

/// Wires the shared bookmark store to the app's settings persistence.
@MainActor
struct SettingsManagerBookmarkPersistence: BookmarkPersisting {
    func load() -> [WallpaperBookmark] { SettingsManager.shared.loadWallpaperBookmarks() }
    func save(_ bookmarks: [WallpaperBookmark]) { SettingsManager.shared.saveWallpaperBookmarks(bookmarks) }
}

extension BookmarkStore {
    /// App-wide singleton backed by `SettingsManager.shared`.
    static let shared = BookmarkStore(persistence: SettingsManagerBookmarkPersistence())
}
