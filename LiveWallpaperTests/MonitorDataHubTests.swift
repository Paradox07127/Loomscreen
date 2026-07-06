import Testing
import Foundation
@testable import LiveWallpaper

@Suite("Monitor data hub")
struct MonitorDataHubTests {
    private func session(
        id: String,
        provider: MonitorAgentProvider,
        status: MonitorAgentStatus,
        lastEventAt: Double
    ) -> MonitorAgentSessionState {
        MonitorAgentSessionState(
            id: id,
            provider: provider,
            projectName: "proj",
            status: status,
            lastEventAt: lastEventAt,
            processAlive: true
        )
    }

    /// Polls the broker until it reports a generation strictly greater than `after`,
    /// or the deadline passes. Returns the newest snapshot seen.
    private func waitForPublish(
        _ broker: MonitorSnapshotBroker,
        after generation: UInt64,
        timeout: TimeInterval = 2.0
    ) async -> MonitorSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = broker.latest(after: generation) {
                return result.snapshot
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return broker.latest(after: generation)?.snapshot
    }

    /// The hub publishes a leading snapshot immediately and coalesces follow-up
    /// updates into a trailing publish — so tests that fire several updates must
    /// wait for the snapshot that actually satisfies the expectation, not just
    /// the first publish.
    private func waitForSnapshot(
        _ broker: MonitorSnapshotBroker,
        timeout: TimeInterval = 2.0,
        until predicate: (MonitorSnapshot) -> Bool
    ) async -> MonitorSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        var newest: MonitorSnapshot?
        while Date() < deadline {
            if let snapshot = broker.latest(after: 0)?.snapshot {
                newest = snapshot
                if predicate(snapshot) { return snapshot }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return newest
    }

    @Test("Modules are nil until their source reports")
    func modulesNilUntilUpdated() async {
        let broker = MonitorSnapshotBroker()
        let hub = MonitorDataHub(broker: broker, throttleInterval: 0.01)

        await hub.updateSystem(MonitorSystemSnapshot(cpuTotal: 0.3))
        let snapshot = await waitForPublish(broker, after: 0)

        #expect(snapshot?.system?.cpuTotal == 0.3)
        #expect(snapshot?.agents == nil)
        #expect(snapshot?.usage == nil)
    }

    @Test("Agents merge across two sources sorted by attention then recency")
    func agentsMergeAndSort() async {
        let broker = MonitorSnapshotBroker()
        let hub = MonitorDataHub(broker: broker, throttleInterval: 0.01)

        await hub.updateAgents(sourceID: "claude", sessions: [
            session(id: "claude:a", provider: .claude, status: .running, lastEventAt: 100),
            session(id: "claude:b", provider: .claude, status: .idle, lastEventAt: 300)
        ])
        await hub.updateAgents(sourceID: "codex", sessions: [
            session(id: "codex:c", provider: .codex, status: .needsInput, lastEventAt: 50),
            session(id: "codex:d", provider: .codex, status: .running, lastEventAt: 200)
        ])

        let snapshot = await waitForSnapshot(broker) { ($0.agents?.count ?? 0) == 4 }
        let ids = snapshot?.agents?.map(\.id)

        // needsInput(4) first, then running(3) by recency (200 > 100), then idle(2).
        #expect(ids == ["codex:c", "codex:d", "claude:a", "claude:b"])
    }

    @Test("Updating one source replaces only that source's sessions")
    func perSourceReplacement() async {
        let broker = MonitorSnapshotBroker()
        let hub = MonitorDataHub(broker: broker, throttleInterval: 0.01)

        await hub.updateAgents(sourceID: "claude", sessions: [
            session(id: "claude:a", provider: .claude, status: .running, lastEventAt: 100)
        ])
        await hub.updateAgents(sourceID: "codex", sessions: [
            session(id: "codex:c", provider: .codex, status: .running, lastEventAt: 100)
        ])
        _ = await waitForPublish(broker, after: 0)
        let before = broker.currentGeneration

        await hub.updateAgents(sourceID: "claude", sessions: [])
        let snapshot = await waitForPublish(broker, after: before)

        #expect(snapshot?.agents?.map(\.id) == ["codex:c"])
    }

    @Test("Disabled module stays nil even if a stray update arrives")
    func disabledModuleStaysNil() async {
        let broker = MonitorSnapshotBroker()
        let hub = MonitorDataHub(broker: broker, throttleInterval: 0.01)

        await hub.setModuleEnabled(agents: false, usage: false)
        await hub.updateAgents(sourceID: "claude", sessions: [
            session(id: "claude:a", provider: .claude, status: .running, lastEventAt: 100)
        ])
        await hub.updateUsage(MonitorUsageSnapshot(costTodayUSD: 5))
        await hub.updateSystem(MonitorSystemSnapshot(cpuTotal: 0.4))

        let snapshot = await waitForSnapshot(broker) { $0.system?.cpuTotal == 0.4 }

        #expect(snapshot?.system?.cpuTotal == 0.4)
        #expect(snapshot?.agents == nil)
        #expect(snapshot?.usage == nil)
    }

    @Test("Re-enabling a module clears prior state until fresh data arrives")
    func reEnableClearsState() async {
        let broker = MonitorSnapshotBroker()
        let hub = MonitorDataHub(broker: broker, throttleInterval: 0.01)

        await hub.updateAgents(sourceID: "claude", sessions: [
            session(id: "claude:a", provider: .claude, status: .running, lastEventAt: 100)
        ])
        _ = await waitForPublish(broker, after: 0)
        let before = broker.currentGeneration

        await hub.setModuleEnabled(agents: false, usage: true)
        let disabled = await waitForPublish(broker, after: before)
        #expect(disabled?.agents == nil)

        // Re-enabling does not resurrect the old array; it stays nil until a source
        // reports again.
        await hub.setModuleEnabled(agents: true, usage: true)
        let reEnabled = broker.latest(after: 0)?.snapshot
        #expect(reEnabled?.agents == nil)
    }

    @Test("Burst of updates coalesces into a leading plus a trailing publish")
    func throttleCoalesces() async {
        let broker = MonitorSnapshotBroker()
        let hub = MonitorDataHub(broker: broker, throttleInterval: 0.3)

        // Fire many rapid updates well inside one throttle window.
        for index in 0..<20 {
            await hub.updateSystem(MonitorSystemSnapshot(cpuTotal: Double(index) / 100))
        }

        // Give the leading publish a beat to land, then read the generation.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let afterBurst = broker.currentGeneration
        #expect(afterBurst >= 1)
        #expect(afterBurst <= 2)

        // The trailing publish carries the final value once the window elapses.
        let final = await waitForPublish(broker, after: afterBurst, timeout: 1.0)
        #expect(final?.system?.cpuTotal == 0.19)
        #expect(broker.currentGeneration <= afterBurst + 1)
    }
}
