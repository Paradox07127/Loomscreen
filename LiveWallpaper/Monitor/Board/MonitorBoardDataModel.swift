import Combine
import Foundation

/// Observable holder for the newest `MonitorSnapshot` the host pumps in, plus
/// the rolling `MonitorHistoryStore` widgets read for sparklines / peaks /
/// session totals.
///
/// The board is externally driven — the runtime pushes snapshots at its own
/// cadence (no self-polling here). Only widget bodies that read live values
/// observe this; placement/edit changes never touch it, so a drag doesn't
/// invalidate widget content and a data tick doesn't re-solve layout.
///
/// History is client-side accumulation only (SPEC §8: charts add no sampling
/// cost) — the store just remembers what the pipeline already pushed.
@MainActor
final class MonitorBoardDataModel: ObservableObject {
    @Published private(set) var snapshot: MonitorSnapshot
    /// Owned rolling-history store. Fed on every `push`; `reset()` on a pump
    /// restart (new session) so stale series don't bleed across sessions.
    let historyStore: MonitorHistoryStore

    init(snapshot: MonitorSnapshot = MonitorSnapshot(), historyCapacity: Int = 120) {
        self.snapshot = snapshot
        self.historyStore = MonitorHistoryStore(capacity: historyCapacity)
    }

    /// Push a fresh snapshot: update the observable value and fold it into the
    /// rolling history. Identical snapshots are dropped to avoid SwiftUI churn.
    func update(_ snapshot: MonitorSnapshot) {
        historyStore.ingest(snapshot)
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
    }

    /// Clear rolling history (pump restarted for a new session). The latest
    /// snapshot is left intact; only the accumulated series reset.
    func resetHistory() {
        historyStore.reset()
    }

    // Convenience accessors used by placeholder tiles.
    var system: MonitorSystemSnapshot? { snapshot.system }

    var cpuPercent: Int? {
        guard let cpu = snapshot.system?.cpuTotal else { return nil }
        return Int((cpu * 100).rounded())
    }

    var memoryPercent: Int? {
        guard let system = snapshot.system, system.memTotalBytes > 0 else { return nil }
        let fraction = Double(system.memUsedBytes) / Double(system.memTotalBytes)
        return Int((fraction * 100).rounded())
    }
}
