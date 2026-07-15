import Foundation

/// Main-target singleton wiring. `BookmarkPersisting` lives in
/// LiveWallpaperCore; the SettingsManager-backed adapter and the
/// `.shared` singleton stay here so Core stays free of the legacy
/// SettingsManager surface.
@MainActor
struct SettingsManagerBookmarkPersistence: BookmarkPersisting {
    func load() -> [WallpaperBookmark] { SettingsManager.shared.loadWallpaperBookmarks() }
    func save(_ bookmarks: [WallpaperBookmark]) { SettingsManager.shared.saveWallpaperBookmarks(bookmarks) }
}

extension BookmarkStore {
    /// App-wide singleton backed by `SettingsManager.shared`. Lite will
    /// supply its own SKU-scoped singleton in Phase 7.
    static let shared = BookmarkStore(persistence: SettingsManagerBookmarkPersistence())
}
