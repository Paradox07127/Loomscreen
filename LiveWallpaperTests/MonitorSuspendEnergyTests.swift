import AppKit
import Foundation
import LiveWallpaperCore
import SwiftUI
import Testing
@testable import LiveWallpaper

/// Verifies that suspension stops producers and board animation loops, not only snapshot delivery.
@Suite("Monitor suspend — energy regression")
struct MonitorSuspendEnergyTests {

    @Test("Pausing the only lease tears the pipeline down, sources and all")
    func pauseStopsPipeline() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietSystemOptions())
        await lease.waitUntilSettled()

        #expect(await runtime.debugActiveSourceCount == 1)
        #expect(await runtime.debugActiveOptions != nil)

        await lease.setPaused(true).value

        #expect(await runtime.debugActiveSourceCount == 0)
        #expect(await runtime.debugActiveOptions == nil)

        await lease.release().value
    }

    @Test("A paused lease is kept, not released — resume stays cheap")
    func pauseRetainsLease() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietSystemOptions())
        await lease.setPaused(true).value

        #expect(await runtime.debugActiveLeaseCount == 1)
        #expect(await runtime.debugPausedLeaseCount == 1)

        await lease.release().value
    }

    @Test("Resuming a paused lease brings the pipeline back")
    func resumeRestartsPipeline() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietSystemOptions())
        await lease.setPaused(true).value
        #expect(await runtime.debugActiveSourceCount == 0)

        await lease.setPaused(false).value
        #expect(await runtime.debugActiveSourceCount == 1)
        #expect(await runtime.debugPausedLeaseCount == 0)

        await lease.release().value
    }

    @Test("One suspended display never starves another that is still visible")
    func pausedLeaseDoesNotStopOtherDisplays() async {
        let runtime = MonitorRuntime()
        let suspended = runtime.makeLeaseSlot().acquire(options: quietSystemOptions(kinds: [.processes]))
        let visible = runtime.makeLeaseSlot().acquire(options: quietSystemOptions(kinds: [.network]))
        await suspended.waitUntilSettled()
        await visible.waitUntilSettled()

        await suspended.setPaused(true).value

        #expect(await runtime.debugActiveSourceCount == 1)
        let options = await runtime.debugActiveOptions
        #expect(options?.activeWidgetKinds == [.network])
        #expect(MonitorRuntime.systemOptions(for: options?.activeWidgetKinds ?? []).topProcesses == false)

        await suspended.release().value
        await visible.release().value
    }

    @Test("A live-config refresh does not silently un-pause a suspended lease")
    func updateOptionsPreservesPause() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietSystemOptions())
        await lease.setPaused(true).value

        await lease.updateOptions(quietSystemOptions(kinds: [.cpu])).value
        #expect(await runtime.debugPausedLeaseCount == 1)
        #expect(await runtime.debugActiveSourceCount == 0)
        #expect(await runtime.debugActiveOptions == nil)

        await lease.release().value
    }

    @Test("An immediate pause is sequenced behind its own acquire")
    func immediatePauseIsHonoured() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietSystemOptions())

        await lease.setPaused(true).value

        #expect(await runtime.debugPausedLeaseCount == 1)
        #expect(await runtime.debugActiveSourceCount == 0)

        await lease.release().value
    }

    @Test("Pausing an already-released lease cannot resurrect it")
    func pauseAfterReleaseDoesNotResurrect() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietSystemOptions())
        await lease.release().value

        await lease.setPaused(false).value
        #expect(await runtime.debugActiveLeaseCount == 0)
        #expect(await runtime.debugActiveSourceCount == 0)
    }

    @Test("A pause trailing its own release cannot poison the next lease on that ID")
    func pauseAfterReleaseCannotPoisonReuse() async {
        let runtime = MonitorRuntime()
        let slot = runtime.makeLeaseSlot()
        let oldLease = slot.acquire(options: quietSystemOptions())
        await oldLease.release().value

        await oldLease.setPaused(true).value

        let newLease = slot.acquire(options: quietSystemOptions())
        await newLease.waitUntilSettled()
        #expect(await runtime.debugPausedLeaseCount == 0)
        #expect(await runtime.debugActiveSourceCount == 1)
        #expect(await runtime.debugActiveOptions != nil)

        await newLease.release().value
    }

    @Test("Every lease paused tears the samplers down but keeps the grants open")
    func pauseKeepsGrantsOpen() async {
        let spy = GrantSpy()
        let runtime = MonitorRuntime(grants: spy.access)
        let lease = runtime.makeLeaseSlot().acquire(options: agentOptions())
        await lease.waitUntilSettled()
        #expect(await spy.resolveCount == 1)

        await lease.setPaused(true).value

        #expect(await runtime.debugActiveOptions == nil)
        #expect(await runtime.debugActiveSourceCount == 0)
        #expect(await spy.releaseCount == 0)

        await lease.setPaused(false).value
        #expect(await runtime.debugActiveOptions != nil)
        #expect(await spy.resolveCount == 1)

        await lease.release().value
        #expect(await spy.releaseCount == 1)
    }

    @Test("Releasing the last lease while it is paused still closes the grants")
    func releaseWhilePausedClosesGrants() async {
        let spy = GrantSpy()
        let runtime = MonitorRuntime(grants: spy.access)
        let lease = runtime.makeLeaseSlot().acquire(options: agentOptions())
        await lease.setPaused(true).value
        #expect(await spy.releaseCount == 0)

        await lease.release().value
        #expect(await spy.releaseCount == 1)
    }

    @Test("A system-only lease holds no grants")
    func systemOnlyLeaseHoldsNoGrants() async {
        let spy = GrantSpy()
        let runtime = MonitorRuntime(grants: spy.access)
        let lease = runtime.makeLeaseSlot().acquire(options: quietSystemOptions())
        await lease.waitUntilSettled()

        #expect(await spy.resolveCount == 0)
        await lease.release().value
    }

    @MainActor
    @Test("applyPerformanceProfile(.suspended) reaches the runtime AND the board")
    func suspendPropagatesFromWallpaperView() async {
        let runtime = MonitorRuntime()
        let view = MonitorWallpaperView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 800),
            configuration: MonitorBoardConfiguration(
                widgets: [MonitorWidgetPlacement(kind: .network, size: .small)],
                refreshHz: 1
            ),
            agentFleetEnabled: false,
            runtime: runtime
        )
        defer { view.cleanup() }

        await view.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveSourceCount == 1)

        view.applyPerformanceProfile(.suspended)
        await view.waitUntilRuntimeSettled()

        #expect(await runtime.debugActiveSourceCount == 0)
        #expect(await runtime.debugActiveOptions == nil)
        #expect(await runtime.debugActiveLeaseCount == 1)
        #expect(await runtime.debugPausedLeaseCount == 1)
        #expect(view.isBoardSuspended == true)

        view.applyPerformanceProfile(.quality)
        await view.waitUntilRuntimeSettled()

        #expect(await runtime.debugActiveSourceCount == 1)
        #expect(await runtime.debugPausedLeaseCount == 0)
        #expect(view.isBoardSuspended == false)
    }

    @MainActor
    @Test("The board host publishes suspend independently of reduce-motion")
    func boardHostCarriesSuspendFlag() {
        let host = MonitorBoardHostView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: MonitorBoardConfiguration(widgets: [], reduceMotionOverride: false),
            agentFleetEnabled: false
        )
        #expect(host.isSuspended == false)

        host.setSuspended(true)
        #expect(host.isSuspended == true)

        host.setSuspended(false)
        #expect(host.isSuspended == false)
    }

    @Test("The board clock ticks 1 Hz while visible")
    func boardClockTicksWhenVisible() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let entries = MonitorBoardClock(suspended: false).entries(from: start, mode: .normal)

        let first = entries.next()
        let second = entries.next()
        let third = entries.next()
        #expect(first == start)
        #expect(second == start.addingTimeInterval(1))
        #expect(third == start.addingTimeInterval(2))
    }

    @Test("A suspended board clock stops after one entry")
    func boardClockStopsWhenSuspended() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let entries = MonitorBoardClock(suspended: true).entries(from: start, mode: .normal)

        #expect(entries.next() == start)
        #expect(entries.next() == nil)
        #expect(entries.next() == nil)
    }

    @MainActor
    @Test("Suspend stills the breathing dot whatever the caller asked for")
    func suspendStillsBreathingDot() {
        #expect(BreathingDot.shouldBreathe(animated: true, reduceMotion: false, suspended: true) == false)
        #expect(BreathingDot.shouldBreathe(animated: true, reduceMotion: true, suspended: true) == false)
        #expect(BreathingDot.shouldBreathe(animated: false, reduceMotion: false, suspended: true) == false)
    }

    @MainActor
    @Test("A visible dot still breathes; reduce-motion still stills it")
    func visibleDotStillBreathes() {
        #expect(BreathingDot.shouldBreathe(animated: true, reduceMotion: false, suspended: false) == true)
        #expect(BreathingDot.shouldBreathe(animated: true, reduceMotion: true, suspended: false) == false)
        #expect(BreathingDot.shouldBreathe(animated: false, reduceMotion: false, suspended: false) == false)
    }

    private func quietSystemOptions(kinds: Set<MonitorWidgetKind> = []) -> MonitorRuntimeOptions {
        var options = MonitorRuntimeOptions(system: true)
        options.activeWidgetKinds = kinds
        return options
    }

    private func agentOptions() -> MonitorRuntimeOptions {
        MonitorRuntimeOptions(system: false, agents: true)
    }

    private actor GrantSpy {
        private(set) var resolveCount = 0
        private(set) var releaseCount = 0

        private static let root = URL(fileURLWithPath: "/dev/null/monitor-grant-spy")

        private func resolve() -> (claude: URL?, codex: URL?) {
            resolveCount += 1
            return (Self.root, nil)
        }

        private func noteRelease() { releaseCount += 1 }

        nonisolated var access: MonitorGrantAccess {
            MonitorGrantAccess(
                resolveRoots: { await self.resolve() },
                release: { await self.noteRelease() }
            )
        }
    }

}
