import Testing
import Foundation
import os
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
        #expect(snapshot.loadAverage1 == snapshot.cpuLoadAvg?.first)

        let health = await sink.health()
        #expect(health?.sourceID == "system")
        #expect(health?.state == "ok")
    }

    @Test("Each published poll samples load averages exactly once", .timeLimit(.minutes(1)))
    func pollSamplesLoadAverageOnce() async {
        let sink = MockSink()
        let samplerCalls = OSAllocatedUnfairLock(initialState: 0)
        let source = SystemMetricsSource(
            includeTopProcesses: false,
            interval: 60,
            loadAverageSampler: {
                samplerCalls.withLock { $0 += 1 }
                return [1.25, 0.75, 0.5]
            }
        )

        await source.start(sink: sink)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await sink.count() >= 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await source.stop()

        let updateCount = await sink.count()
        let callCount = samplerCalls.withLock { $0 }
        #expect(updateCount == 1)
        #expect(callCount == updateCount)
        let snapshot = await sink.system()
        #expect(snapshot?.loadAverage1 == 1.25)
        #expect(snapshot?.cpuLoadAvg == [1.25, 0.75, 0.5])
    }

    @Test("Stopping halts further updates")
    func stopHaltsUpdates() async {
        let sink = MockSink()
        let source = SystemMetricsSource(includeTopProcesses: false, interval: 0.3)

        await source.start(sink: sink)
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
