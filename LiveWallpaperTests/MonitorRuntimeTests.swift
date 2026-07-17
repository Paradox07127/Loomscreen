import Testing
import Foundation
import os
@testable import LiveWallpaper

@Suite("Monitor runtime leases")
struct MonitorRuntimeTests {
    private var quietOptions: MonitorRuntimeOptions {
        // system:false keeps tests free of real samplers; no factories fire
        // because agents/usage stay false.
        MonitorRuntimeOptions(system: false)
    }

    @Test("A queued release is sequenced after its acquire")
    func releaseIsSequencedAfterAcquire() async {
        let runtime = MonitorRuntime()
        let slot = runtime.makeLeaseSlot()
        let lease = slot.acquire(options: quietOptions)

        // No await between the calls: the slot must establish the command order
        // before either detached task reaches the runtime actor.
        await lease.release().value

        #expect(await runtime.debugActiveLeaseCount == 0)
        #expect(await runtime.debugLeaseBookkeepingCount == 0)
    }

    @Test("Balanced acquire then release ends with no live leases")
    func balancedLifecycle() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietOptions)

        await lease.waitUntilSettled()
        #expect(await runtime.debugActiveLeaseCount == 1)

        await lease.release().value
        #expect(await runtime.debugActiveLeaseCount == 0)
    }

    @Test("updateOptions on a released lease can't resurrect it")
    func updateOptionsNeverResurrects() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietOptions)

        await lease.waitUntilSettled()
        await lease.release().value
        #expect(await runtime.debugActiveLeaseCount == 0)

        await lease.updateOptions(quietOptions).value
        #expect(await runtime.debugActiveLeaseCount == 0)
    }

    @Test("updateOptions mutates a live lease without changing its count")
    func updateOptionsRefreshesLiveLease() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietOptions)

        await lease.waitUntilSettled()
        var refreshed = quietOptions
        refreshed.topProcesses = true
        await lease.updateOptions(refreshed).value

        #expect(await runtime.debugActiveLeaseCount == 1)
        await lease.release().value
    }

    @Test("An older generation cannot update, pause, or release the current lease")
    func staleGenerationCannotMutateCurrentLease() async {
        let runtime = MonitorRuntime()
        let slot = runtime.makeLeaseSlot()
        let older = slot.acquire(options: quietOptions)
        await older.waitUntilSettled()

        var currentOptions = quietOptions
        currentOptions.topProcesses = true
        let current = slot.acquire(options: currentOptions)
        await current.waitUntilSettled()
        #expect(older.generation < current.generation)

        await older.updateOptions(quietOptions).value
        await older.setPaused(true).value
        await older.release().value

        #expect(await runtime.debugActiveLeaseCount == 1)
        #expect(await runtime.debugPausedLeaseCount == 0)
        let activeOptions = await runtime.debugActiveOptions
        #expect(activeOptions?.topProcesses == true)

        await current.release().value
        #expect(await runtime.debugLeaseBookkeepingCount == 0)
    }

    @Test("Pipeline options are the union across all live leases")
    func mergedOptionsUnion() {
        var systemOnly = MonitorRuntimeOptions(system: true)
        systemOnly.topProcesses = true
        var agentsOnly = MonitorRuntimeOptions(system: false)
        agentsOnly.agents = true
        agentsOnly.usage = true
        agentsOnly.claudeRoot = URL(fileURLWithPath: "/tmp/claude")

        let merged = MonitorRuntime.merged([systemOnly, agentsOnly])

        #expect(merged?.system == true)
        #expect(merged?.agents == true)
        #expect(merged?.usage == true)
        #expect(merged?.topProcesses == true)
        #expect(merged?.claudeRoot == URL(fileURLWithPath: "/tmp/claude"))
        #expect(MonitorRuntime.merged([]) == nil)
    }

    @Test("Final release clears the broker so stale snapshots can't replay")
    func finalReleaseClearsBroker() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietOptions)

        await lease.waitUntilSettled()
        runtime.broker.publish(MonitorSnapshot(timestamp: 1))
        #expect(runtime.broker.latest(after: 0) != nil)

        await lease.release().value
        #expect(runtime.broker.latest(after: 0) == nil)
    }

    @Test("A second display's differing lease widens, not replaces, the pipeline")
    func secondLeaseWidens() async {
        let runtime = MonitorRuntime(
            grants: MonitorGrantAccess(
                resolveRoots: { (claude: nil, codex: nil) },
                release: {}
            ),
            sourceFactories: []
        )
        var agentLease = quietOptions
        agentLease.agents = true
        let first = runtime.makeLeaseSlot().acquire(options: quietOptions)
        let second = runtime.makeLeaseSlot().acquire(options: agentLease)

        await first.waitUntilSettled()
        await second.waitUntilSettled()
        #expect(await runtime.debugActiveLeaseCount == 2)

        // Dropping the agent lease narrows back down; dropping both stops all.
        await second.release().value
        #expect(await runtime.debugActiveLeaseCount == 1)
        await first.release().value
        #expect(await runtime.debugActiveLeaseCount == 0)
    }

    @Test("Termination awaits every producer before final cursor and settings flushes", .timeLimit(.minutes(1)))
    func terminationOrdersProducerStopBeforeFinalFlush() async {
        let probe = TerminationOrderProbe()
        let source = BlockingTerminationSource(probe: probe)
        let grants = MonitorGrantAccess(
            resolveRoots: { (claude: nil, codex: nil) },
            release: {}
        )
        let runtime = MonitorRuntime(
            grants: grants,
            sourceFactories: [{ _ in [source] }]
        )
        var options = quietOptions
        options.agents = true
        let lease = runtime.makeLeaseSlot().acquire(options: options)

        await lease.waitUntilSettled()
        #expect(await runtime.debugActiveSourceCount == 1)

        let termination = Task { @MainActor in
            await AppTerminationCoordinator.run(
                stopMonitorProducers: { await runtime.shutdown() },
                flushMonitorCursors: { await probe.record("cursor-flush") },
                flushSettings: { await probe.record("settings-flush") }
            )
        }

        // Hold source.stop() in-flight. Neither final persistence step may run
        // while a producer can still mutate the cursor generation.
        await probe.waitUntilStopEntered()
        #expect(await probe.events == ["producer-stop-entered"])

        // A duplicate quit request must share the same shutdown barrier rather
        // than invoke source.stop() twice or deadlock the actor.
        let duplicateShutdown = Task { await runtime.shutdown() }
        await Task.yield()
        #expect(await probe.stopInvocationCount == 1)

        await probe.allowStopToFinish()
        await termination.value
        await duplicateShutdown.value

        #expect(await probe.events == [
            "producer-stop-entered",
            "producer-complete",
            "cursor-flush",
            "settings-flush",
        ])
        #expect(await probe.stopInvocationCount == 1)
        #expect(await runtime.debugIsTerminated)
        #expect(await runtime.debugActiveLeaseCount == 0)
        #expect(await runtime.debugActiveSourceCount == 0)

        // Cleanup tasks launched by views can arrive after the barrier. A stale
        // acquire must not resurrect a producer behind the final flush.
        let staleLease = runtime.makeLeaseSlot().acquire(options: options)
        await staleLease.waitUntilSettled()
        #expect(await runtime.debugActiveLeaseCount == 0)
        #expect(await runtime.debugActiveSourceCount == 0)
    }

    @Test("A blocked cursor flush leaves the MainActor watchdog runnable", .timeLimit(.minutes(1)))
    func blockingCursorFlushDoesNotStarveMainActor() async {
        let flushEntered = OSAllocatedUnfairLock(initialState: false)
        let releaseFlush = DispatchSemaphore(value: 0)
        let mainActorReached = OSAllocatedUnfairLock(initialState: false)

        // Match AppDelegate's call site: termination begins from MainActor, but
        // the synchronous cursor writer must leave that executor immediately.
        let flush = Task { @MainActor in
            await AppTerminationCoordinator.runBlockingOffMainActor {
                flushEntered.withLock { $0 = true }
                releaseFlush.wait()
            }
        }
        let entryDeadline = Date().addingTimeInterval(2)
        while !flushEntered.withLock({ $0 }), Date() < entryDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(flushEntered.withLock { $0 })

        let watchdog = Task { @MainActor in
            mainActorReached.withLock { $0 = true }
        }
        let deadline = Date().addingTimeInterval(1)
        while !mainActorReached.withLock({ $0 }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let reachedBeforeRelease = mainActorReached.withLock { $0 }

        releaseFlush.signal()
        await flush.value
        await watchdog.value

        #expect(
            reachedBeforeRelease,
            "MainActor was starved while the detached cursor flush was blocked"
        )
    }
}

private actor TerminationOrderProbe {
    private(set) var events: [String] = []
    private(set) var stopInvocationCount = 0

    private var stopEntered = false
    private var stopEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopCanFinish = false
    private var stopFinishWaiter: CheckedContinuation<Void, Never>?

    func producerStop() async {
        stopInvocationCount += 1
        events.append("producer-stop-entered")
        stopEntered = true
        let waiters = stopEnteredWaiters
        stopEnteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        if !stopCanFinish {
            await withCheckedContinuation { continuation in
                stopFinishWaiter = continuation
            }
        }
        events.append("producer-complete")
    }

    func waitUntilStopEntered() async {
        guard !stopEntered else { return }
        await withCheckedContinuation { continuation in
            stopEnteredWaiters.append(continuation)
        }
    }

    func allowStopToFinish() {
        stopCanFinish = true
        stopFinishWaiter?.resume()
        stopFinishWaiter = nil
    }

    func record(_ event: String) {
        events.append(event)
    }
}

private actor BlockingTerminationSource: MonitorDataSource {
    nonisolated let sourceID = "blocking-termination-source"
    private let probe: TerminationOrderProbe

    init(probe: TerminationOrderProbe) {
        self.probe = probe
    }

    func start(sink: any MonitorSnapshotSink) async {}

    func stop() async {
        await probe.producerStop()
    }
}
