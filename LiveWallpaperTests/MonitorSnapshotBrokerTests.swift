import Testing
@testable import LiveWallpaper

@Suite("Monitor snapshot broker")
struct MonitorSnapshotBrokerTests {
    private func snapshot(cpu: Double) -> MonitorSnapshot {
        MonitorSnapshot(system: MonitorSystemSnapshot(cpuTotal: cpu))
    }

    @Test("Fresh broker returns nil for any generation")
    func freshBrokerReturnsNil() {
        let broker = MonitorSnapshotBroker()

        #expect(broker.latest(after: 0) == nil)
        #expect(broker.currentGeneration == 0)
    }

    @Test("Publish makes a snapshot available after generation 0")
    func publishAvailableAfterZero() {
        let broker = MonitorSnapshotBroker()
        broker.publish(snapshot(cpu: 0.5))

        let result = broker.latest(after: 0)

        #expect(result?.generation == 1)
        #expect(result?.snapshot.system?.cpuTotal == 0.5)
    }

    @Test("latest(after:) is nil once the caller is current")
    func nilWhenCallerCurrent() {
        let broker = MonitorSnapshotBroker()
        broker.publish(snapshot(cpu: 0.5))

        guard let first = broker.latest(after: 0) else {
            Issue.record("expected a first snapshot")
            return
        }

        #expect(broker.latest(after: first.generation) == nil)
    }

    @Test("A newer publish supersedes the stale cursor")
    func newerPublishSupersedes() {
        let broker = MonitorSnapshotBroker()
        broker.publish(snapshot(cpu: 0.1))
        let first = broker.latest(after: 0)
        broker.publish(snapshot(cpu: 0.2))

        let second = broker.latest(after: first?.generation ?? 0)

        #expect(second?.generation == 2)
        #expect(second?.snapshot.system?.cpuTotal == 0.2)
    }

    @Test("Generation rises monotonically across publishes")
    func generationMonotonic() {
        let broker = MonitorSnapshotBroker()
        for index in 1...5 {
            broker.publish(snapshot(cpu: Double(index) / 10))
        }

        #expect(broker.currentGeneration == 5)
        #expect(broker.latest(after: 4)?.snapshot.system?.cpuTotal == 0.5)
    }

    @Test("Concurrent publishes and reads stay safe")
    func concurrentPublishAndRead() async {
        let broker = MonitorSnapshotBroker()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<1000 {
                    broker.publish(self.snapshot(cpu: Double(index % 100) / 100))
                }
            }
            group.addTask {
                var cursor: UInt64 = 0
                for _ in 0..<1000 {
                    if let result = broker.latest(after: cursor) {
                        cursor = result.generation
                    }
                }
            }
        }

        #expect(broker.currentGeneration == 1000)
        #expect(broker.latest(after: 0)?.generation == 1000)
    }
}
