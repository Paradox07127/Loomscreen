import AppKit
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("MON-01 MonitorRuntime sequenced lease churn", .serialized)
struct MonitorRuntimeLeaseChurnCharacterizationTests {
    @Test("10,000 generations leave no retired bookkeeping", .timeLimit(.minutes(1)))
    func tenThousandGenerationsHaveFixedBookkeeping() async {
        let runtime = makeRuntime()
        let slot = runtime.makeLeaseSlot()

        for index in 0 ..< 10000 {
            let lease = slot.acquire(options: Self.options(UInt64(index)))
            await lease.release().value
        }

        #expect(await runtime.debugActiveLeaseCount == 0)
        #expect(await runtime.debugPausedLeaseCount == 0)
        #expect(await runtime.debugActiveOptions == nil)
        #expect(await runtime.debugActiveSourceCount == 0)
        #expect(await runtime.debugLeaseBookkeepingCount == 0)

        await runtime.shutdown()
        #expect(await runtime.debugIsTerminated)
    }

    @Test("Fixed-seed 10,000-event churn rejects stale-generation mutations", .timeLimit(.minutes(1)))
    func randomizedStaleGenerationEventsStayBounded() async {
        let runtime = makeRuntime()
        let slotCount = 64
        let slots = (0 ..< slotCount).map { _ in runtime.makeLeaseSlot() }
        var current: [MonitorRuntimeLeaseHandle?] = Array(repeating: nil, count: slotCount)
        var currentOptions: [MonitorRuntimeOptions?] = Array(repeating: nil, count: slotCount)
        var paused = Array(repeating: false, count: slotCount)
        var stale = Array(repeating: [MonitorRuntimeLeaseHandle](), count: slotCount)
        var random = SplitMix64(state: 0x4D4F_4E2D_3031_5EED)
        var staleEventCount = 0

        for eventIndex in 0 ..< 10000 {
            let index = Int(random.next() % UInt64(slotCount))
            let roll = random.next() % 100

            if roll < 30 {
                if let previous = current[index] {
                    stale[index].append(previous)
                }
                let options = Self.options(random.next())
                let lease = slots[index].acquire(options: options)
                current[index] = lease
                currentOptions[index] = options
                paused[index] = false
                await lease.waitUntilSettled()
            } else {
                let targetsStale = !stale[index].isEmpty && random.next() % 3 == 0
                let target: MonitorRuntimeLeaseHandle?
                if targetsStale {
                    target = stale[index][Int(random.next() % UInt64(stale[index].count))]
                    staleEventCount += 1
                } else {
                    target = current[index]
                }

                switch roll {
                case 30 ..< 55:
                    if let target {
                        await target.release().value
                        if !targetsStale, current[index] === target {
                            current[index] = nil
                            currentOptions[index] = nil
                            paused[index] = false
                        }
                    }
                case 55 ..< 78:
                    let requestedPause = random.next() & 1 == 0
                    if let target {
                        await target.setPaused(requestedPause).value
                        if !targetsStale, current[index] === target {
                            paused[index] = requestedPause
                        }
                    }
                default:
                    let options = Self.options(random.next())
                    if let target {
                        await target.updateOptions(options).value
                        if !targetsStale, current[index] === target {
                            currentOptions[index] = options
                        }
                    }
                }
            }

            if eventIndex.isMultiple(of: 127) {
                await Self.expectRuntime(
                    runtime,
                    current: current,
                    options: currentOptions,
                    paused: paused,
                    eventIndex: eventIndex
                )
            }
        }

        await Self.expectRuntime(
            runtime,
            current: current,
            options: currentOptions,
            paused: paused,
            eventIndex: 9999
        )
        #expect(staleEventCount > 0)

        for lease in current.compactMap(\.self) {
            await lease.release().value
        }
        #expect(await runtime.debugLeaseBookkeepingCount == 0)

        await runtime.shutdown()
        #expect(await runtime.debugIsTerminated)
    }

    @Test("A blocked rebuild bounds 10,000 commands across 64 active slots", .timeLimit(.minutes(1)))
    func blockedRebuildHasBoundedMailbox() async {
        let probe = MonitorRuntimeStopProbe()
        let source = BlockingMonitorRuntimeStopSource(probe: probe)
        let runtime = MonitorRuntime(
            grants: MonitorGrantAccess(
                resolveRoots: { (claude: nil, codex: nil) },
                release: {}
            ),
            sourceFactories: [{ _ in [source] }]
        )
        let slots = (0 ..< 64).map { _ in runtime.makeLeaseSlot() }
        let leases = slots.map { $0.acquire(options: Self.options(1)) }
        for lease in leases {
            await lease.waitUntilSettled()
        }
        #expect(await runtime.debugActiveLeaseCount == 64)

        let initialRevision = await runtime.debugRebuildRevision
        let launchesBeforeBlock = await runtime.debugRebuildWorkerLaunchCount

        leases[0].updateOptions(Self.options(0))
        await probe.waitUntilStopEntered()
        #expect(await runtime.debugRebuildWorkerCount == 1)
        #expect(await runtime.debugRebuildWorkerLaunchCount == launchesBeforeBlock + 1)

        for index in 1 ..< slots.count {
            leases[index].updateOptions(Self.options(UInt64(index + 2)))
        }
        let allSlotsEnteredActor = await Self.waitUntilRebuildRevision(
            runtime,
            reaches: initialRevision + UInt64(slots.count)
        )
        #expect(allSlotsEnteredActor)
        #expect(await runtime.debugActiveLeaseCount == 64)

        let blockedRevision = await runtime.debugRebuildRevision
        let blockedLaunchCount = await runtime.debugRebuildWorkerLaunchCount
        let drainLaunchCounts = slots.map(\.debugDrainLaunchCount)

        for event in 0 ..< 10000 {
            let index = event % slots.count
            if event.isMultiple(of: 2) {
                leases[index].updateOptions(Self.options(UInt64(event + 100)))
            } else {
                leases[index].setPaused(event.isMultiple(of: 3))
            }
        }

        var releaseTasks: [Task<Void, Never>] = []
        releaseTasks.reserveCapacity(leases.count)
        for lease in leases {
            releaseTasks.append(lease.release())
        }

        let totalPending = slots.reduce(0) { $0 + $1.debugPendingCommandCount }
        let totalWorkers = slots.reduce(0) { $0 + $1.debugDrainWorkerCount }
        #expect(slots.allSatisfy { $0.debugPendingCommandCount <= 1 })
        #expect(slots.allSatisfy { $0.debugDrainWorkerCount <= 1 })
        #expect(totalPending == slots.count)
        #expect(totalWorkers == slots.count)
        #expect(slots.map(\.debugDrainLaunchCount) == drainLaunchCounts)
        #expect(await runtime.debugRebuildWorkerCount == 1)
        #expect(await runtime.debugRebuildWorkerLaunchCount == blockedLaunchCount)
        #expect(await runtime.debugRebuildRevision == blockedRevision)

        await probe.allowStopToFinish()
        for task in releaseTasks {
            await task.value
        }

        #expect(slots.allSatisfy { $0.debugPendingCommandCount == 0 })
        #expect(slots.allSatisfy { $0.debugDrainWorkerCount == 0 })
        #expect(await runtime.debugActiveLeaseCount == 0)
        #expect(await runtime.debugLeaseBookkeepingCount == 0)
        await runtime.shutdown()
    }

    @MainActor
    @Test("Wallpaper board edits repoint the production lease before persistence round-trip")
    func wallpaperBoardEditRefreshesLeaseImmediately() async {
        let runtime = makeRuntime()
        let view = MonitorWallpaperView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: MonitorBoardConfiguration(widgets: []),
            agentFleetEnabled: true,
            runtime: runtime
        )
        await view.waitUntilRuntimeSettled()

        let fleet = MonitorBoardConfiguration(widgets: [
            MonitorWidgetPlacement(kind: .fleet, size: .medium),
        ])
        view.acceptBoardConfigurationEdit(fleet)
        await view.waitUntilRuntimeSettled()

        let editedOptions = await runtime.debugActiveOptions
        #expect(editedOptions?.activeWidgetKinds == [.fleet])
        #expect(editedOptions?.agents == true)
        #expect(editedOptions?.system == false)

        view.apply(configuration: fleet)
        #expect(await runtime.debugActiveOptions == editedOptions)

        view.applyPerformanceProfile(.suspended)
        await view.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveLeaseCount == 1)
        #expect(await runtime.debugPausedLeaseCount == 1)
        #expect(await runtime.debugActiveOptions == nil)

        view.applyPerformanceProfile(.quality)
        await view.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveLeaseCount == 1)
        #expect(await runtime.debugPausedLeaseCount == 0)
        #expect(await runtime.debugActiveOptions == editedOptions)

        view.cleanup()
        await view.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveLeaseCount == 0)
        await runtime.shutdown()
    }

    @MainActor
    @Test("HUD hide and show replace generations without leaking a lease")
    func hudHideShowOwnsOneLease() async {
        let runtime = makeRuntime()
        let hud = MonitorHUDController(
            initiallyEnabled: true,
            runtime: runtime,
            persistEnabled: { _ in }
        )

        hud.show()
        await hud.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveLeaseCount == 1)

        hud.hide()
        hud.show()
        await hud.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveLeaseCount == 1)

        hud.shutdown()
        await hud.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveLeaseCount == 0)
        hud.show()
        #expect(!hud.hasRuntimeLease)
        await runtime.shutdown()
    }

    @MainActor
    @Test("HUD repeated hide and shutdown preserve an in-flight release barrier")
    func hudRepeatedHideKeepsReleaseBarrier() async {
        let stopProbe = MonitorRuntimeStopProbe()
        let source = BlockingMonitorRuntimeStopSource(probe: stopProbe)
        let runtime = MonitorRuntime(
            grants: MonitorGrantAccess(
                resolveRoots: { (claude: nil, codex: nil) },
                release: {}
            ),
            sourceFactories: [{ _ in [source] }]
        )
        let hud = MonitorHUDController(
            initiallyEnabled: true,
            runtime: runtime,
            persistEnabled: { _ in }
        )

        hud.show()
        await hud.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveLeaseCount == 1)

        hud.hide()
        await stopProbe.waitUntilStopEntered()
        hud.shutdown()
        hud.hide()

        let waitProbe = MonitorRuntimeWaitProbe()
        let waiter = Task { @MainActor in
            await waitProbe.markEntered()
            await hud.waitUntilRuntimeSettled()
            await waitProbe.markCompleted()
        }
        await waitProbe.waitUntilEntered()
        await Self.allowCompletionOpportunity(waitProbe)
        #expect(!(await waitProbe.isCompleted))

        await stopProbe.allowStopToFinish()
        await waiter.value
        #expect(await waitProbe.isCompleted)
        #expect(await runtime.debugActiveLeaseCount == 0)
        await runtime.shutdown()
    }

    @MainActor
    @Test("Overlay active, paused, resumed, and released states own exactly one lease")
    func overlayStateChurnOwnsOneLease() async {
        let runtime = makeRuntime()
        let controller = MonitorOverlayController(runtime: runtime)
        let screenID: CGDirectDisplayID = 77
        let overlay = MonitorOverlayConfiguration(
            enabled: true,
            level: .front,
            board: MonitorBoardConfiguration(widgets: [])
        )

        controller.apply(
            overlay: overlay,
            screenID: screenID,
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
            agentFleetEnabled: false
        )
        await controller.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveLeaseCount == 1)
        #expect(await runtime.debugPausedLeaseCount == 0)

        controller.updateVisibility(isUserAbsent: true, occludedScreenIDs: [])
        await controller.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveLeaseCount == 1)
        #expect(await runtime.debugPausedLeaseCount == 1)

        controller.updateVisibility(isUserAbsent: false, occludedScreenIDs: [])
        await controller.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveLeaseCount == 1)
        #expect(await runtime.debugPausedLeaseCount == 0)

        controller.teardownAll()
        await controller.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveLeaseCount == 0)
        await runtime.shutdown()
    }

    private func makeRuntime() -> MonitorRuntime {
        MonitorRuntime(
            grants: MonitorGrantAccess(
                resolveRoots: { (claude: nil, codex: nil) },
                release: {}
            ),
            sourceFactories: []
        )
    }

    private static func expectRuntime(
        _ runtime: MonitorRuntime,
        current: [MonitorRuntimeLeaseHandle?],
        options: [MonitorRuntimeOptions?],
        paused: [Bool],
        eventIndex: Int
    ) async {
        let expectedActiveCount = current.compactMap(\.self).count
        let expectedPausedCount = current.indices.filter {
            current[$0] != nil && paused[$0]
        }.count
        let expectedOptions = MonitorRuntime.merged(current.indices.compactMap { index in
            guard current[index] != nil, !paused[index] else { return nil }
            return options[index]
        })

        #expect(
            await runtime.debugActiveLeaseCount == expectedActiveCount,
            "lease count diverged after event \(eventIndex)"
        )
        #expect(
            await runtime.debugPausedLeaseCount == expectedPausedCount,
            "pause count diverged after event \(eventIndex)"
        )
        #expect(
            await runtime.debugActiveOptions == expectedOptions,
            "merged options diverged after event \(eventIndex)"
        )
        #expect(
            await runtime.debugLeaseBookkeepingCount <= 64,
            "lease bookkeeping exceeded the fixed slot bound after event \(eventIndex)"
        )
    }

    private static func options(_ token: UInt64) -> MonitorRuntimeOptions {
        var options = MonitorRuntimeOptions(system: false)
        options.topProcesses = token & 1 == 0
        options.gpuSampleSeconds = token % 3 == 0 ? Double((token % 5) + 1) * 2 : nil
        return options
    }

    private static func waitUntilRebuildRevision(
        _ runtime: MonitorRuntime,
        reaches target: UInt64
    ) async -> Bool {
        for _ in 0 ..< 10000 {
            if await runtime.debugRebuildRevision >= target { return true }
            await Task.yield()
        }
        return await runtime.debugRebuildRevision >= target
    }

    private static func allowCompletionOpportunity(
        _ probe: MonitorRuntimeWaitProbe
    ) async {
        for _ in 0 ..< 256 {
            if await probe.isCompleted { return }
            await Task.yield()
        }
    }
}

private actor MonitorRuntimeStopProbe {
    private var stopEntered = false
    private var stopEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldBlockNextStop = true
    private var stopFinishWaiter: CheckedContinuation<Void, Never>?

    func sourceStop() async {
        guard shouldBlockNextStop else { return }
        shouldBlockNextStop = false
        stopEntered = true
        let waiters = stopEnteredWaiters
        stopEnteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            stopFinishWaiter = continuation
        }
    }

    func waitUntilStopEntered() async {
        guard !stopEntered else { return }
        await withCheckedContinuation { continuation in
            stopEnteredWaiters.append(continuation)
        }
    }

    func allowStopToFinish() {
        stopFinishWaiter?.resume()
        stopFinishWaiter = nil
    }
}

private actor BlockingMonitorRuntimeStopSource: MonitorDataSource {
    nonisolated let sourceID = "monitor-runtime-stop-source"
    private let probe: MonitorRuntimeStopProbe

    init(probe: MonitorRuntimeStopProbe) {
        self.probe = probe
    }

    func start(sink _: any MonitorSnapshotSink) async {}

    func stop() async {
        await probe.sourceStop()
    }
}

private actor MonitorRuntimeWaitProbe {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isCompleted = false

    func markEntered() {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func markCompleted() {
        isCompleted = true
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
