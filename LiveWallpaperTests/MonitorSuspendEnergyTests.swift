import AppKit
import Foundation
import LiveWallpaperCore
import SwiftUI
import Testing
@testable import LiveWallpaper

/// Energy regression net for the Monitor wallpaper's suspend path.
///
/// This exists because `suspend()` has twice been written as "stop the pump" plus
/// a comment claiming everything else follows. It does not follow: the pump is
/// only the CONSUMER. The runtime's samplers (per-PID walk, SMC round-trips) and
/// the board's self-driven loops (1 Hz clock, breathing dots) each need telling,
/// and a board that renders nothing new looks identical to one that costs
/// nothing — so no visual test and no snapshot test can catch the regression.
///
/// Each test below asserts on a mechanism that ACTUALLY stops work:
///   • the runtime lease drops out of the merged options ⇒ sources torn down,
///   • the board clock's schedule ends ⇒ TimelineView requests no more frames,
///   • `BreathingDot.shouldBreathe` goes false ⇒ no `repeatForever`.
/// Rewriting `suspend()` back into a no-op fails these, not a screenshot.
@Suite("Monitor suspend — energy regression")
struct MonitorSuspendEnergyTests {

    // MARK: - Runtime lease pause (the producer)

    @Test("Pausing the only lease tears the pipeline down, sources and all")
    func pauseStopsPipeline() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietSystemOptions())
        await lease.waitUntilSettled()

        // Live: the system source exists and is polling.
        #expect(await runtime.debugActiveSourceCount == 1)
        #expect(await runtime.debugActiveOptions != nil)

        await lease.setPaused(true).value

        // The point of C1: not merely "no snapshots delivered" but "nothing is
        // sampling". No sources ⇒ no proc_pidinfo walk, no SMC IPC.
        #expect(await runtime.debugActiveSourceCount == 0)
        #expect(await runtime.debugActiveOptions == nil)

        await lease.release().value
    }

    @Test("A paused lease is kept, not released — resume stays cheap")
    func pauseRetainsLease() async {
        let runtime = MonitorRuntime()
        let lease = runtime.makeLeaseSlot().acquire(options: quietSystemOptions())
        await lease.setPaused(true).value

        // Releasing instead would drop the resolved security-scoped grants and
        // make every resume pay to re-open them.
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

        // Pipeline stays up for the visible screen — but the expensive walk the
        // suspended screen alone demanded is gone from the union.
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

        // A board edit on a suspended wallpaper round-trips through updateOptions;
        // it must not resurrect the samplers.
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

        // No await between acquire and pause: the slot owns their order instead
        // of relying on detached-task scheduling.
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
        // HUD and overlay keep one slot across every show/hide, so a new
        // generation in the same slot is routine.
        let slot = runtime.makeLeaseSlot()
        let oldLease = slot.acquire(options: quietSystemOptions())
        await oldLease.release().value

        // Issued while the lease was alive, landing after the release took it
        // away. Filing it as a pause-before-acquire would leave an entry nothing
        // ever clears, and the next lease on this ID would start suspended.
        await oldLease.setPaused(true).value

        let newLease = slot.acquire(options: quietSystemOptions())
        await newLease.waitUntilSettled()
        #expect(await runtime.debugPausedLeaseCount == 0)
        #expect(await runtime.debugActiveSourceCount == 1)
        #expect(await runtime.debugActiveOptions != nil)

        await newLease.release().value
    }

    // MARK: - Security-scoped grants follow the lease, not the pipeline

    @Test("Every lease paused tears the samplers down but keeps the grants open")
    func pauseKeepsGrantsOpen() async {
        let spy = GrantSpy()
        let runtime = MonitorRuntime(grants: spy.access)
        let lease = runtime.makeLeaseSlot().acquire(options: agentOptions())
        await lease.waitUntilSettled()
        #expect(await spy.resolveCount == 1)

        await lease.setPaused(true).value

        // The samplers are gone — that is C1, and it must stay true…
        #expect(await runtime.debugActiveOptions == nil)
        #expect(await runtime.debugActiveSourceCount == 0)
        // …but the scopes the live lease holds are not, so there is nothing for
        // the resume to re-open. Binding scope lifetime to the PIPELINE (which
        // stops here) is what made the "cheap resume" claim false.
        #expect(await spy.releaseCount == 0)

        await lease.setPaused(false).value
        #expect(await runtime.debugActiveOptions != nil)
        // The resume resolved no bookmark: it reused the roots still held open.
        #expect(await spy.resolveCount == 1)

        // The LEASE ending — not the pipeline stopping — is what closes them.
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

        // The pipeline is already down, so this release leaves the merged target
        // at nil — unchanged. Reconciling grants only when the pipeline rebuilds
        // would leak the scopes past the last lease's life.
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

    // MARK: - The wallpaper view (C1 itself)

    /// THE C1 regression test: the view is what was broken — it stopped its pump
    /// and told nobody else. Re-deleting either call in `suspend()` fails here.
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

        // Producer stopped…
        #expect(await runtime.debugActiveSourceCount == 0)
        #expect(await runtime.debugActiveOptions == nil)
        // …lease kept, so resume doesn't re-resolve grants…
        #expect(await runtime.debugActiveLeaseCount == 1)
        #expect(await runtime.debugPausedLeaseCount == 1)
        // …and the board's own loops were told too.
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
        // reduceMotionOverride: false ⇒ the accessibility lever is explicitly OFF,
        // so anything that stills the board here did so because of suspend.
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

    // MARK: - Board clock (H2)

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

        // One entry so the last frame carries an accurate `now`, then the schedule
        // ENDS — TimelineView asks for nothing more. A `.periodic` schedule (what
        // v2 shipped) has no off switch and would keep scheduling vsync work.
        #expect(entries.next() == start)
        #expect(entries.next() == nil)
        #expect(entries.next() == nil)
    }

    // MARK: - Breathing dot (H1)

    @MainActor
    @Test("Suspend stills the breathing dot whatever the caller asked for")
    func suspendStillsBreathingDot() {
        // The hottest call site is `BreathingDot(animated: pct > 60)` — it breathes
        // exactly when the machine is already hot. Suspend must win over it.
        #expect(BreathingDot.shouldBreathe(animated: true, reduceMotion: false, suspended: true) == false)
        #expect(BreathingDot.shouldBreathe(animated: true, reduceMotion: true, suspended: true) == false)
        #expect(BreathingDot.shouldBreathe(animated: false, reduceMotion: false, suspended: true) == false)
    }

    @MainActor
    @Test("A visible dot still breathes; reduce-motion still stills it")
    func visibleDotStillBreathes() {
        #expect(BreathingDot.shouldBreathe(animated: true, reduceMotion: false, suspended: false) == true)
        // Reduce-motion is the user's accessibility preference and keeps working
        // on its own — suspend is a separate lever, not a replacement.
        #expect(BreathingDot.shouldBreathe(animated: true, reduceMotion: true, suspended: false) == false)
        #expect(BreathingDot.shouldBreathe(animated: false, reduceMotion: false, suspended: false) == false)
    }

    // MARK: - Helpers

    /// System-only lease with every expensive sampler gated off, so the test
    /// exercises the lease/pause plumbing without doing real PID or SMC walks.
    private func quietSystemOptions(kinds: Set<MonitorWidgetKind> = []) -> MonitorRuntimeOptions {
        var options = MonitorRuntimeOptions(system: true)
        options.activeWidgetKinds = kinds
        return options
    }

    /// A lease that wants AI data — the only kind that resolves grants — with the
    /// system source off so no real sampler runs.
    private func agentOptions() -> MonitorRuntimeOptions {
        MonitorRuntimeOptions(system: false, agents: true)
    }

    /// Counts what the runtime does to the security-scoped grants. Injected
    /// because the real `MonitorSourceAuthorization` resolves nothing in a test
    /// process, so "the resume re-opened nothing" is otherwise unobservable —
    /// which is precisely how the claim survived in a comment while being false.
    private actor GrantSpy {
        private(set) var resolveCount = 0
        private(set) var releaseCount = 0

        /// Unreachable path: any agent source built on it finds no files.
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
