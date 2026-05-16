import Foundation

/// Serial off-MainActor writer for the screen-configuration AtomicFileStore.
///
/// Each MainActor caller assigns a monotonically increasing `generation`
/// before submitting a write or delete. The actor drops any task whose
/// generation is older than the most recently committed one, so even if
/// Swift's task scheduler reorders concurrent submissions the disk only
/// ever moves forward — the most-recent UI commit wins, and stale writes
/// can't resurrect superseded state (including deletes from a Reset
/// settings flow).
public actor WallpaperPersistenceActor {
    private let store: AtomicFileStore<[ScreenConfiguration]>
    private var latestGeneration: UInt64 = 0

    public init(store: AtomicFileStore<[ScreenConfiguration]>) {
        self.store = store
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
}
