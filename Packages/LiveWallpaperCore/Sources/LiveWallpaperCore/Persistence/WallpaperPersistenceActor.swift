import Foundation

/// Serial off-MainActor writer for the file-backed settings stores
/// (screen configurations, global settings, wallpaper bookmarks).
///
/// Each MainActor caller assigns a monotonically increasing `generation`
/// before submitting a write or delete. The actor drops any task whose
/// generation is older than the most recently committed one, so even if
/// Swift's task scheduler reorders concurrent submissions the disk only
/// ever moves forward — the most-recent UI commit wins, and stale writes
/// can't resurrect superseded state (including deletes from a Reset
/// settings flow). Generations are tracked per store so the three blobs
/// don't supersede one another; routing all three through one actor keeps
/// their disk writes serialized (no interleaved fsync/rename contention)
/// and lets a single drain flush them all before termination.
public actor WallpaperPersistenceActor {
    private let store: AtomicFileStore<[ScreenConfiguration]>
    private let globalSettingsStore: AtomicFileStore<GlobalSettings>
    private let bookmarksStore: AtomicFileStore<[WallpaperBookmark]>
    private var latestGeneration: UInt64 = 0
    private var latestGlobalGeneration: UInt64 = 0
    private var latestBookmarksGeneration: UInt64 = 0

    public init(
        store: AtomicFileStore<[ScreenConfiguration]>,
        globalSettingsStore: AtomicFileStore<GlobalSettings>,
        bookmarksStore: AtomicFileStore<[WallpaperBookmark]>
    ) {
        self.store = store
        self.globalSettingsStore = globalSettingsStore
        self.bookmarksStore = bookmarksStore
    }

    public func write(_ configs: [ScreenConfiguration], generation: UInt64) throws {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation
        try store.write(configs)
    }

    public func delete(generation: UInt64) {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation
        store.delete()
    }

    public func writeGlobalSettings(_ settings: GlobalSettings, generation: UInt64) throws {
        guard generation >= latestGlobalGeneration else { return }
        latestGlobalGeneration = generation
        try globalSettingsStore.write(settings)
    }

    public func writeBookmarks(_ bookmarks: [WallpaperBookmark], generation: UInt64) throws {
        guard generation >= latestBookmarksGeneration else { return }
        latestBookmarksGeneration = generation
        try bookmarksStore.write(bookmarks)
    }

    public func deleteGlobalSettings(generation: UInt64) {
        guard generation >= latestGlobalGeneration else { return }
        latestGlobalGeneration = generation
        globalSettingsStore.delete()
    }

    public func deleteBookmarks(generation: UInt64) {
        guard generation >= latestBookmarksGeneration else { return }
        latestBookmarksGeneration = generation
        bookmarksStore.delete()
    }
}
