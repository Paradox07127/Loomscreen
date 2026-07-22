import Combine
import Foundation

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

    /// Stores a new snapshot unless it is unchanged.
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
