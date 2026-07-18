import Foundation

/// `SerialExecutor` that runs actor jobs on a `WPERenderThread`. Pairing an actor's
/// `unownedExecutor` with this makes the actor's isolation domain *be* the render
/// thread — see SE-0392 (custom actor executors).
///
/// `@unchecked Sendable`: holds only an immutable reference to the (Sendable)
/// render thread; it has no mutable state of its own.
final class WPERenderThreadExecutor: SerialExecutor, @unchecked Sendable {

    private let thread: WPERenderThread

    init(thread: WPERenderThread) {
        self.thread = thread
    }

    func enqueue(_ job: consuming ExecutorJob) {
        // A job that never runs traps the runtime, so consumption must be
        // unconditional. `perform` runs the block on the render thread while it is
        // live, and inline on the caller after shutdown — either way the job runs.
        let unowned = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        thread.perform {
            unowned.runSynchronously(on: executor)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Gives `assumeIsolated`/`assertIsolated` teeth: when the runtime can't prove
    /// isolation via the fast path (e.g. inside a bare CADisplayLink/RunLoop
    /// callback, where no Swift task executor is active), it falls back here. We
    /// answer authoritatively by checking real thread identity.
    func checkIsolated() {
        precondition(
            thread.isCurrent,
            "WPERenderThreadExecutor.checkIsolated: not on the render thread"
        )
    }
}
