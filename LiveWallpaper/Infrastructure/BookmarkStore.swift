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
        var loaded = persistence.load()
        var didMigrate = false
        for index in loaded.indices where loaded[index].sourceDisplayName == nil {
            loaded[index].sourceDisplayName = Self.defaultSourceDisplayName(for: loaded[index].content) ?? ""
            didMigrate = true
        }
        self.bookmarks = loaded
        if didMigrate {
            persistence.save(loaded)
        }
    }

    /// Append a new bookmark and persist immediately.
    @discardableResult
    func add(
        label: String,
        content: WallpaperContent,
        sourceDisplayName: String? = nil,
        wpeOrigin: WPEOrigin? = nil
    ) -> WallpaperBookmark {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSourceDisplayName = sourceDisplayName
            ?? Self.nonResolvingSourceDisplayName(for: content)
            ?? ""
        let resolved = trimmed.isEmpty
            ? Self.defaultLabel(for: content, sourceDisplayName: resolvedSourceDisplayName)
            : trimmed
        let bookmark = WallpaperBookmark(
            label: resolved,
            content: content,
            sourceDisplayName: resolvedSourceDisplayName,
            wpeOrigin: wpeOrigin
        )
        bookmarks.append(bookmark)
        persist()
        Logger.info("Bookmark added: type \(content.wallpaperType.rawValue), total \(bookmarks.count)", category: .ui)
        return bookmark
    }

    func remove(_ id: UUID) {
        let removedType = bookmarks.first(where: { $0.id == id })?.wallpaperType.rawValue ?? "Unknown"
        bookmarks.removeAll { $0.id == id }
        persist()
        Logger.info("Bookmark removed: type \(removedType), total \(bookmarks.count)", category: .ui)
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
        Logger.info("Bookmark renamed: type \(bookmarks[index].wallpaperType.rawValue)", category: .ui)
    }

    /// True when an equivalent content is already saved (so UI can disable
    /// the "Save" button instead of producing duplicates).
    func contains(_ content: WallpaperContent) -> Bool {
        bookmarks.contains { $0.content == content }
    }

    func containsWPEBookmark(workshopID: String) -> Bool {
        bookmarks.contains { Self.matchesWPEBookmark($0, workshopID: workshopID) }
    }

    func removeWPEBookmarks(workshopID: String) {
        let removedCount = bookmarks.filter { Self.matchesWPEBookmark($0, workshopID: workshopID) }.count
        guard removedCount > 0 else { return }

        bookmarks.removeAll { Self.matchesWPEBookmark($0, workshopID: workshopID) }
        persist()
        Logger.info("WPE bookmarks removed: workshop \(workshopID), count \(removedCount), total \(bookmarks.count)", category: .ui)
    }

    private func persist() {
        persistence.save(bookmarks)
    }

    private static func matchesWPEBookmark(_ bookmark: WallpaperBookmark, workshopID: String) -> Bool {
        if bookmark.wpeOrigin?.workshopID == workshopID {
            return true
        }
        return bookmark.content.sceneDescriptor?.workshopID == workshopID
    }

    /// Friendly fallback label derived from the content itself.
    static func defaultLabel(for content: WallpaperContent, sourceDisplayName: String? = nil) -> String {
        switch content {
        case .video:
            if let trimmed = sourceDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return trimmed
            }
            return "Video"
        case .html(let source, _):
            return source.displayName
        case .metalShader(let preset):
            return preset.localizedTitle
        case .scene(let descriptor):
            return String(localized: "Scene \(descriptor.workshopID)", comment: "Default bookmark label for a Wallpaper Engine scene. The placeholder is the Workshop ID.")
        }
    }

    static func nonResolvingSourceDisplayName(for content: WallpaperContent) -> String? {
        switch content {
        case .video:
            return nil
        case .html(let source, _):
            return source.displayName
        case .metalShader(let preset):
            return preset.localizedTitle
        case .scene(let descriptor):
            return String(localized: "Scene \(descriptor.workshopID)", comment: "Default source label for a Wallpaper Engine scene. The placeholder is the Workshop ID.")
        }
    }

    static func defaultSourceDisplayName(for content: WallpaperContent) -> String? {
        switch content {
        case .video(let bookmarkData):
            return ResourceUtilities.resolveBookmarkName(bookmarkData)
        case .html(let source, _):
            return source.displayName
        case .metalShader(let preset):
            return preset.localizedTitle
        case .scene(let descriptor):
            return String(localized: "Scene \(descriptor.workshopID)", comment: "Default source label for a Wallpaper Engine scene. The placeholder is the Workshop ID.")
        }
    }
}
