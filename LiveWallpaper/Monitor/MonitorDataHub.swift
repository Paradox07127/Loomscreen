import Foundation

/// Fan-in point for all `MonitorDataSource`s. Sources push partial updates (system
/// metrics, one provider's agent sessions, usage, health) whenever they have news;
/// the hub keeps the last value per slot, recomposes a full `MonitorSnapshot`, and
/// publishes it to the broker — but no more than `throttleInterval` apart, so a burst
/// of source updates collapses into at most one leading + one trailing publish.
///
/// A module that has never reported stays `nil` in the composed snapshot (the
/// dashboard reads `nil` as "module disabled / no data"). `setModuleEnabled` lets the
/// runtime force a slot back to `nil` so a late in-flight update from a torn-down
/// source can't resurrect a disabled module.
actor MonitorDataHub: MonitorSnapshotSink {
    private let broker: MonitorSnapshotBroker
    private let throttleInterval: TimeInterval

    private var system: MonitorSystemSnapshot?
    private var agentsBySource: [String: [MonitorAgentSessionState]] = [:]
    private var usage: MonitorUsageSnapshot?
    private var healthBySource: [String: MonitorSourceHealth] = [:]

    private var agentsEnabled = true
    private var usageEnabled = true

    private var lastPublish: Date?
    private var trailingTask: Task<Void, Never>?

    /// `throttleInterval` is injectable so tests can drive coalescing without waiting
    /// real seconds; production uses the 0.5s (≤2Hz) cadence.
    init(broker: MonitorSnapshotBroker, throttleInterval: TimeInterval = 0.5) {
        self.broker = broker
        self.throttleInterval = throttleInterval
    }

    // MARK: - MonitorSnapshotSink

    func updateSystem(_ snapshot: MonitorSystemSnapshot) async {
        system = snapshot
        schedulePublish()
    }

    func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async {
        guard agentsEnabled else { return }
        agentsBySource[sourceID] = sessions
        schedulePublish()
    }

    func updateUsage(_ usage: MonitorUsageSnapshot) async {
        guard usageEnabled else { return }
        self.usage = usage
        schedulePublish()
    }

    func updateHealth(_ health: MonitorSourceHealth) async {
        healthBySource[health.sourceID] = health
        schedulePublish()
    }

    // MARK: - Module gating

    /// Disable a module: clears its accumulated state and blocks future updates so
    /// the composed snapshot reports `nil` for it until re-enabled.
    func setModuleEnabled(agents: Bool, usage: Bool) {
        agentsEnabled = agents
        usageEnabled = usage
        if !agents { agentsBySource.removeAll() }
        if !usage { self.usage = nil }
        schedulePublish()
    }

    // MARK: - Throttled publish

    private func schedulePublish() {
        let now = Date()
        if let last = lastPublish, now.timeIntervalSince(last) < throttleInterval {
            scheduleTrailingPublish(after: last)
        } else {
            publishNow(at: now)
        }
    }

    private func scheduleTrailingPublish(after last: Date) {
        guard trailingTask == nil else { return }
        let delay = throttleInterval - Date().timeIntervalSince(last)
        let nanos = UInt64(max(0, delay) * 1_000_000_000)
        trailingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            await self?.firePendingTrailingPublish()
        }
    }

    private func firePendingTrailingPublish() {
        trailingTask = nil
        publishNow(at: Date())
    }

    private func publishNow(at date: Date) {
        lastPublish = date
        broker.publish(compose(at: date))
    }

    private func compose(at date: Date) -> MonitorSnapshot {
        MonitorSnapshot(
            timestamp: date.timeIntervalSince1970,
            system: system,
            agents: composedAgents(),
            usage: usage,
            health: composedHealth()
        )
    }

    /// Merge every source's sessions, most attention-worthy first, then most
    /// recently active. `nil` (not empty) while no agent source has reported so the
    /// dashboard can pick the system-only hero layout.
    private func composedAgents() -> [MonitorAgentSessionState]? {
        guard agentsEnabled, !agentsBySource.isEmpty else { return nil }
        let merged = agentsBySource.values.flatMap { $0 }
        return merged.sorted { lhs, rhs in
            let lp = lhs.status.attentionPriority
            let rp = rhs.status.attentionPriority
            if lp != rp { return lp > rp }
            return lhs.lastEventAt > rhs.lastEventAt
        }
    }

    private func composedHealth() -> [MonitorSourceHealth]? {
        guard !healthBySource.isEmpty else { return nil }
        return healthBySource.values.sorted { $0.sourceID < $1.sourceID }
    }
}
