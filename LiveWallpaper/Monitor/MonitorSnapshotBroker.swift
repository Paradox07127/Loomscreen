import Foundation
import os

/// Hand-off point between the `MonitorDataHub` (single writer) and the per-display renderers (many readers, polling at their own cadence).
final class MonitorSnapshotBroker: Sendable {
    private struct State {
        var latest: MonitorSnapshot?
        var generation: UInt64 = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func publish(_ snapshot: MonitorSnapshot) {
        lock.withLock { state in
            state.latest = snapshot
            state.generation &+= 1
        }
    }

    /// Newest snapshot strictly newer than `generation`, or `nil` when the caller is already current (or nothing has been published yet).
    func latest(after generation: UInt64) -> (snapshot: MonitorSnapshot, generation: UInt64)? {
        lock.withLock { state in
            guard let snapshot = state.latest, state.generation > generation else {
                return nil
            }
            return (snapshot, state.generation)
        }
    }

    /// Current generation without consuming a snapshot — lets a fresh reader seed
    /// its cursor at 0 or discover how far behind it is.
    var currentGeneration: UInt64 {
        lock.withLock { $0.generation }
    }

    /// Drops retained data and advances the generation so new renderers cannot replay a stale snapshot.
    func clear() {
        lock.withLock { state in
            state.latest = nil
            state.generation &+= 1
        }
    }
}
