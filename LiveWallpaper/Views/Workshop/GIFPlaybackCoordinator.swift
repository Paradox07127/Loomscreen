#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import Foundation

/// Background pausing is owned by the coordinator's app-resign observer — this
/// app hosts SwiftUI in AppKit windows, so SwiftUI `scenePhase` is unreliable
/// here and is NOT gated on.
struct ThumbnailPlaybackGate: Equatable {
    enum Trigger: Equatable { case hover, auto }

    /// Hover debounce so a fast sweep across a grid doesn't thrash the decoder.
    static let hoverPreviewDelayNanoseconds: UInt64 = 250_000_000

    var isVisible: Bool
    var isHovered: Bool
    var reduceMotion: Bool
    var isBlurred: Bool
    var trigger: Trigger

    var allowsPlayback: Bool {
        isVisible && triggerAllowsPlayback && !reduceMotion && !isBlurred
    }

    private var triggerAllowsPlayback: Bool {
        switch trigger {
        case .hover: return isHovered
        case .auto: return true
        }
    }
}

/// Bounds the number of GIF/APNG previews animating at once via an LRU cap,
/// freezing evicted clients to their poster frame. With hover-to-play as the
/// default the cap is rarely approached; it remains a defensive limit for
/// `.autoPlay` callers and pathological grids.
///
/// Also freezes every client when the app resigns active. Resumption is
/// gate-driven (`ThumbnailPlaybackGate`): on reactivation a tile replays only
/// if its gate is satisfied again, so backgrounded windows stay quiet.
@MainActor
final class GIFPlaybackCoordinator {
    static let shared = GIFPlaybackCoordinator()

    private static let maxActiveClients = 8

    /// LRU order: front = least-recently-used, back = most-recent.
    private var lruOrder: [UUID] = []
    private var freezers: [UUID: () -> Void] = [:]

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

    /// Evicts the LRU client if the cap is exceeded — never the caller, which
    /// is moved to most-recent first.
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

    func allowsPlayback(_ gate: ThumbnailPlaybackGate) -> Bool {
        gate.allowsPlayback
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
