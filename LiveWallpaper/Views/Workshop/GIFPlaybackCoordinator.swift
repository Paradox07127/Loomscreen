#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import Foundation

/// Bounds the number of GIF/APNG previews animating at once. Clients register
/// when they begin playback and the coordinator evicts the least-recently-used
/// client past a hard cap, calling its `freeze` closure so it falls back to its
/// poster frame. With hover-to-play as the default, the cap is rarely
/// approached (the mouse hovers one card at a time); it remains a defensive
/// limit for `.autoPlay` callers and pathological grids.
///
/// Also freezes every client when the app resigns active, and — per the plan —
/// does NOT auto-resume on reactivation (playback restarts only on a fresh
/// hover) so backgrounded windows stay quiet.
@MainActor
final class GIFPlaybackCoordinator {
    static let shared = GIFPlaybackCoordinator()

    private static let maxActiveClients = 8

    /// LRU order: front = least-recently-used, back = most-recent.
    private var lruOrder: [UUID] = []
    private var freezers: [UUID: () -> Void] = [:]

    /// Production code uses `shared`; an internal initializer exists so tests
    /// can exercise the LRU policy on an isolated instance.
    ///
    /// The resign-active observer is intentionally never removed: `shared`
    /// lives for the whole process, and the block captures `self` weakly so a
    /// deallocated test instance simply no-ops. (Swift 6 also forbids touching
    /// the non-Sendable observer token from a nonisolated `deinit`.)
    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.freezeAll() }
        }
    }

    /// Registers `id` as actively playing. Evicts the LRU client if the cap is
    /// exceeded (never the caller, which is moved to most-recent first).
    func requestPlayback(id: UUID, freeze: @escaping () -> Void) {
        freezers[id] = freeze
        touch(id: id)
        while lruOrder.count > Self.maxActiveClients {
            let evicted = lruOrder.removeFirst()
            freezers.removeValue(forKey: evicted)?()
        }
    }

    func endPlayback(id: UUID) {
        lruOrder.removeAll { $0 == id }
        freezers.removeValue(forKey: id)
    }

    /// Marks `id` as most-recently-used so steady playback isn't evicted.
    func touch(id: UUID) {
        lruOrder.removeAll { $0 == id }
        lruOrder.append(id)
    }

    private func freezeAll() {
        let active = freezers
        lruOrder.removeAll()
        freezers.removeAll()
        for freeze in active.values { freeze() }
    }
}
#endif
