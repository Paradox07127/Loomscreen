import Foundation
import os

/// Hand-off point between the `MonitorDataHub` (single writer) and the per-display
/// renderers (many readers, polling at their own cadence). A monotonically rising
/// `generation` lets a reader ask "anything newer than what I last drew?" and get
/// `nil` when there isn't, so an idle board does no work between updates.
///
/// Unlike `AudioSpectrumBroker` this never runs on a realtime thread, so a plain
/// blocking lock is fine — the critical section is a struct copy, uncontended in
/// practice (one writer at ≤2Hz, readers at frame cadence).
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

    /// Newest snapshot strictly newer than `generation`, or `nil` when the caller
    /// is already current (or nothing has been published yet). Pass `0` to always
    /// receive the first available snapshot.
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

    /// Drops the retained snapshot (still bumping the generation) so a renderer
    /// that attaches after the pipeline stopped or was reconfigured can't replay
    /// stale module data from the previous run.
    func clear() {
        lock.withLock { state in
            state.latest = nil
            state.generation &+= 1
        }
    }
}
