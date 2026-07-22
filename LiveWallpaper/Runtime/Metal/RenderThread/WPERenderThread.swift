import Foundation
import QuartzCore

/// Persistent serial render thread with a live run loop for display-link callbacks.
/// Initialization handoff and mutable lifecycle state are synchronized before cross-thread access.
final class WPERenderThread: @unchecked Sendable {

    enum State {
        case running
        /// `shutdown()` has begun but the render thread is still draining queued
        /// work. New work must NOT run inline yet — doing so would overlap the
        /// still-draining thread and break the `SerialExecutor` mutual-exclusion
        /// contract. Late posts block until the drain finishes (`.stopped`).
        case stopping
        /// The render thread has drained its queue and the loop has stopped, so no
        /// further render-thread job can run. New work now runs inline on the
        /// caller (serialized via `postShutdownLock`) with nothing to overlap.
        case stopped
    }

    /// One-shot handoff of the run loop from the render thread back to `init`,
    /// consumed under the ready semaphore. `@unchecked Sendable`: written once on
    /// the render thread, read once on the init thread with the semaphore as the
    /// happens-before edge.
    private final class LoopHandoff: @unchecked Sendable {
        var nsRunLoop: RunLoop?
        var cfRunLoop: CFRunLoop?
        var pthread: pthread_t?
    }

    /// Guards `state` and signals the `.stopping → .stopped` transition so a
    /// late `perform` can block until the drain finishes instead of racing it.
    private let stateCondition = NSCondition()
    private var state: State = .running

    /// Serializes work that arrives *after* shutdown. Post-shutdown jobs run inline
    /// on arbitrary caller threads, so mutual exclusion (the actual `SerialExecutor`
    /// contract — not same-thread) has to be re-established with a lock. Recursive
    /// because an inline job may itself re-enqueue synchronously.
    private let postShutdownLock = NSRecursiveLock()

    private let backingThread: Thread
    private let finishedSemaphore = DispatchSemaphore(value: 0)

    /// Populated by the time `init` returns and never mutated afterward.
    private let nsRunLoop: RunLoop
    private let cfRunLoop: CFRunLoop
    /// The render thread's own `pthread_t`, so `shutdown()` can lift its QoS while
    /// a higher-QoS caller blocks on the join (adaptive drops it to `.utility`).
    private let backingPThread: pthread_t

    /// Escape hatch: `defaults write <bundle> loomscreen.wallpapers.adaptiveRenderQoS.v1 -bool NO`
    /// pins the render thread at `.userInteractive` (the pre-adaptive behaviour).
    /// Default ON.
    static let adaptiveQoSDefaultsKey = "loomscreen.wallpapers.adaptiveRenderQoS.v1"

    static var adaptiveQoSEnabledFromDefaults: Bool {
        UserDefaults.standard.object(forKey: adaptiveQoSDefaultsKey) as? Bool ?? true
    }

    /// Adaptive-QoS state machine. Mutated ONLY on the render thread (via
    /// `noteFrameDuration` / `boostRenderQoSWarmup` / `setFrameBudget`), which is
    /// serial — so no lock, matching this class's `@unchecked Sendable` contract.
    private var adaptiveQoS: WPEAdaptiveRenderQoS

    init(label: String = "com.livewallpaper.render", adaptiveQoSEnabled: Bool? = nil) {
        let adaptiveEnabled = adaptiveQoSEnabled ?? Self.adaptiveQoSEnabledFromDefaults
        self.adaptiveQoS = WPEAdaptiveRenderQoS(isEnabled: adaptiveEnabled)
        let handoff = LoopHandoff()
        let ready = DispatchSemaphore(value: 0)
        let finished = finishedSemaphore

        let thread = Thread {
            autoreleasepool {
                let ns = RunLoop.current
                let cf = ns.getCFRunLoop()
                // A bare port is the keep-alive source so the loop never exits for
                // lack of sources; the run loop retains it, so no stored ref needed.
                ns.add(NSMachPort(), forMode: .common)

                handoff.nsRunLoop = ns
                handoff.cfRunLoop = cf
                handoff.pthread = pthread_self()
                ready.signal()

                // Runs until a scheduled block calls CFRunLoopStop; the port keeps
                // it from returning early when idle.
                CFRunLoopRun()
            }
            finished.signal()
        }
        thread.name = label
        // Base stays `.userInteractive`; the adaptive drop to `.utility` is applied
        // ON the render thread lazily, on the first frame (see `noteFrameDuration`).
        // Keeping the base high until frames actually flow means the warm-up window
        // and any non-rendering caller (which would otherwise block on a low-QoS
        // thread) never hit a priority inversion.
        thread.qualityOfService = .userInteractive
        self.backingThread = thread

        thread.start()
        ready.wait()
        self.nsRunLoop = handoff.nsRunLoop!
        self.cfRunLoop = handoff.cfRunLoop!
        self.backingPThread = handoff.pthread!
    }

    // MARK: - Introspection

    /// True when the caller is executing on this render thread — the isolation
    /// oracle for `checkIsolated()` / `assumeIsolated`.
    var isCurrent: Bool { Thread.current === backingThread }

    /// The run loop that accepts main-thread-created display links.
    var runLoop: RunLoop { nsRunLoop }

    // MARK: - Work delivery

    /// Post `block` to run on the render thread, FIFO after all earlier posts.
    /// After shutdown the loop is gone, so the block runs inline on the caller
    /// (serialized via `postShutdownLock`) — it is never dropped.
    func perform(_ block: @escaping @Sendable () -> Void) {
        stateCondition.lock()
        switch state {
        case .running:
            // Enqueue under the lock so ordering vs. shutdown's stop block is
            // deterministic: a post seen as `.running` always lands before the
            // stop block and is drained, never dropped.
            CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.commonModes.rawValue, block)
            CFRunLoopWakeUp(cfRunLoop)
            stateCondition.unlock()
        case .stopping:
            // The render thread is still draining. Wait for the stop block to
            // publish `.stopped` (it runs after the queue drains, on the render
            // thread) before running inline — otherwise this inline job would
            // overlap the drain and break mutual exclusion.
            while state == .stopping { stateCondition.wait() }
            stateCondition.unlock()
            runInline(block)
        case .stopped:
            stateCondition.unlock()
            runInline(block)
        }
    }

    private func runInline(_ block: @Sendable () -> Void) {
        postShutdownLock.lock()
        defer { postShutdownLock.unlock() }
        block()
    }

    // MARK: - Adaptive QoS
    //
    // All three entries mutate `adaptiveQoS` and must run ON this render thread —
    // that is where `pthread_set_qos_class_self_np` takes effect and where the
    // serial-thread guarantee makes the lock-free state machine safe. The frame
    // path (`WPEDisplayRenderActor.renderFrame`) and load/reload tails already run
    // here; debug builds assert it.

    /// True once the OS thread's QoS has been synced to the state machine's tier —
    /// deferred to the first frame so the thread's `.userInteractive` base holds
    /// until frames actually flow. Render-thread-only.
    private var didSyncInitialQoS = false

    /// Feed one frame-body duration to the QoS controller and apply a tier change
    /// on this thread if the window crossed a threshold.
    func noteFrameDuration(_ seconds: Double) {
        assert(isCurrent, "noteFrameDuration must run on the render thread")
        // First frame: drop the (userInteractive-based) thread onto the state
        // machine's starting tier — `.utility` when adaptive, a no-op when pinned.
        if !didSyncInitialQoS {
            didSyncInitialQoS = true
            applyQoS(adaptiveQoS.level)
        }
        if let level = adaptiveQoS.record(frameDuration: seconds) {
            applyQoS(level)
        }
    }

    /// Pin `.high` for the first `frames` frames after a scene load/reload, so the
    /// heavy warm-up (lazy shader transpile) isn't throttled onto the E-cores.
    func boostRenderQoSWarmup(frames: Int = 120) {
        assert(isCurrent, "boostRenderQoSWarmup must run on the render thread")
        adaptiveQoS.boost(frames: frames)
    }

    /// Retarget the budget at the live cadence (called when preferred fps changes).
    func setFrameBudget(seconds: Double) {
        assert(isCurrent, "setFrameBudget must run on the render thread")
        adaptiveQoS.setBudget(seconds: seconds)
    }

    private func applyQoS(_ level: WPEAdaptiveRenderQoS.Level) {
        let qos: qos_class_t
        switch level {
        case .economy: qos = QOS_CLASS_UTILITY
        case .high: qos = QOS_CLASS_USER_INTERACTIVE
        }
        pthread_set_qos_class_self_np(qos, 0)
    }

    // MARK: - Run-loop attachment
    //
    // Timers/display links are added via direct calls (thread-safe under CFRunLoop)
    // then the loop is woken; no closure crosses the thread, so no Sendable
    // relaxation is needed.

    func add(_ timer: Timer, forMode mode: RunLoop.Mode = .common) {
        nsRunLoop.add(timer, forMode: mode)
        CFRunLoopWakeUp(cfRunLoop)
    }

    func add(_ displayLink: CADisplayLink, forMode mode: RunLoop.Mode = .common) {
        displayLink.add(to: nsRunLoop, forMode: mode)
        CFRunLoopWakeUp(cfRunLoop)
    }

    // MARK: - Shutdown

    /// Drain all queued work, stop the loop, and join. Idempotent. If called from
    /// the render thread itself it cannot join (would deadlock), so it only
    /// schedules the stop and returns.
    func shutdown() {
        let cf = cfRunLoop
        stateCondition.lock()
        guard state == .running else { stateCondition.unlock(); return }
        state = .stopping
        // FIFO: scheduled under the lock, so this stop block runs after every block
        // posted while `state` was `.running`, and queued work drains first. The
        // stop block runs on the render thread once the queue is empty, so it is
        // the correct place to publish `.stopped`: at that point no further
        // render-thread job can run, so an inline post can no longer overlap one.
        CFRunLoopPerformBlock(cf, CFRunLoopMode.commonModes.rawValue) { [self] in
            stateCondition.lock()
            state = .stopped
            stateCondition.broadcast()
            stateCondition.unlock()
            CFRunLoopStop(cf)
        }
        CFRunLoopWakeUp(cf)
        stateCondition.unlock()

        if isCurrent { return }
        // The caller (often main / user-initiated) is about to block on the join
        // while the render thread may sit at `.utility` — a priority inversion the
        // Thread Performance Checker flags and that can stall teardown. Lift the
        // render thread to `.userInteractive` for the drain, then release.
        let override = pthread_override_qos_class_start_np(
            backingPThread, QOS_CLASS_USER_INTERACTIVE, 0
        )
        finishedSemaphore.wait()
        pthread_override_qos_class_end_np(override)
    }
}
