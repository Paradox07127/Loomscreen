import Testing
import Foundation
@testable import LiveWallpaper

@Suite("System metrics source")
struct SystemMetricsSourceTests {
    private actor MockSink: MonitorSnapshotSink {
        private(set) var lastSystem: MonitorSystemSnapshot?
        private(set) var systemUpdateCount = 0
        private(set) var lastHealth: MonitorSourceHealth?

        func updateSystem(_ snapshot: MonitorSystemSnapshot) async {
            lastSystem = snapshot
            systemUpdateCount += 1
        }
        func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async {}
        func updateUsage(_ usage: MonitorUsageSnapshot) async {}
        func updateHealth(_ health: MonitorSourceHealth) async { lastHealth = health }

        func system() -> MonitorSystemSnapshot? { lastSystem }
        func health() -> MonitorSourceHealth? { lastHealth }
        func count() -> Int { systemUpdateCount }
    }

    @Test("Source emits a plausible system snapshot", .timeLimit(.minutes(1)))
    func emitsSystemSnapshot() async {
        let sink = MockSink()
        let source = SystemMetricsSource(includeTopProcesses: false, interval: 0.5)

        await source.start(sink: sink)

        // Poll for up to ~3s; the first tick fires immediately but delta-based CPU
        // needs a second sample, so wait for at least two updates when possible.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if await sink.count() >= 2 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await source.stop()

        guard let snapshot = await sink.system() else {
            Issue.record("no system snapshot arrived within the timeout")
            return
        }

        #expect(snapshot.memTotalBytes > 0)
        #expect(snapshot.memUsedBytes > 0)
        #expect(snapshot.cpuTotal >= 0)
        #expect(snapshot.cpuTotal <= 1)
        #expect(snapshot.uptimeSeconds > 0)

        let health = await sink.health()
        #expect(health?.sourceID == "system")
        #expect(health?.state == "ok")
    }

    @Test("Stopping halts further updates")
    func stopHaltsUpdates() async {
        let sink = MockSink()
        let source = SystemMetricsSource(includeTopProcesses: false, interval: 0.3)

        await source.start(sink: sink)
        // Let at least one tick land.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await sink.count() >= 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await source.stop()

        let countAfterStop = await sink.count()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let countLater = await sink.count()

        #expect(countLater == countAfterStop)
    }
}
