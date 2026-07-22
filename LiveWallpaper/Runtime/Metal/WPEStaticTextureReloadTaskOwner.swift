#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Generation-scoped owner for on-demand static-texture reload tasks. Admission
/// closes atomically with task detachment, so a reload can drain a stable set.
///
/// Stays `@MainActor` because its admission bookkeeping must be ordered
/// deterministically against its callers — a caller that just `submit`ted
/// observes `canPublish == true` before the spawned task can run (same-executor
/// scheduling), which an owner-`actor` version cannot guarantee (the task could
/// complete during the caller's hop back). The renderer reaches it from the
/// render actor via `await`; the reload *operation* hops to the render actor to
/// touch renderer state, so the owner itself never touches the renderer.
@MainActor
final class WPEStaticTextureReloadTaskOwner {
    struct Ticket: Hashable, Sendable {
        let path: String
        let generation: Int
        fileprivate let token: UUID
    }

    struct Drain: Sendable {
        fileprivate let tasks: [Task<Void, Never>]

        func wait() async {
            for task in tasks {
                await task.value
            }
        }
    }

    private struct Handle {
        let ticket: Ticket
        let task: Task<Void, Never>
    }

    /// Flattens a same-frame decode/upload spike; 2 is not a tuned value.
    private static let maxConcurrentReloads = 2
    /// Below this, a couple of paths reloading together isn't worth logging.
    private static let burstLogThreshold = 3

    private var currentGeneration: Int?
    private var handles: [String: Handle] = [:]
    private(set) var isAccepting = false

    private(set) var activeReloadCount = 0
    private var reloadWaiters: [CheckedContinuation<Void, Never>] = []

    private var burstDispatchCount = 0
    /// Set alongside `burstDispatchCount` on every dispatch, so it always
    /// holds the latest generation by the time `flushBurstLog` reads it.
    private var burstLogGeneration = 0
    private var burstLogScheduled = false

    /// `nonisolated` so the (nonisolated) renderer's stored-property initializer
    /// can construct the owner; no isolated state is touched here.
    nonisolated init() {}

    var pendingPaths: Set<String> {
        Set(handles.keys)
    }

    var taskCount: Int {
        handles.count
    }

    func resume(generation: Int) {
        currentGeneration = generation
        isAccepting = true
    }

    @discardableResult
    func submit(
        path: String,
        generation: Int,
        priority: TaskPriority = .utility,
        operation: @escaping @MainActor @Sendable (Ticket) async -> Void
    ) -> Ticket? {
        guard isAccepting,
              currentGeneration == generation,
              handles[path] == nil else { return nil }

        let ticket = Ticket(path: path, generation: generation, token: UUID())
        let task = Task(priority: priority) { @MainActor [weak self] in
            await self?.acquireReloadSlot()
            await operation(ticket)
            self?.releaseReloadSlot()
            self?.finish(ticket)
        }
        handles[path] = Handle(ticket: ticket, task: task)
        noteBurstDispatch(generation: generation)
        return ticket
    }

    func canPublish(_ ticket: Ticket) -> Bool {
        guard isAccepting,
              currentGeneration == ticket.generation,
              let handle = handles[ticket.path] else { return false }
        return handle.ticket.token == ticket.token && !handle.task.isCancelled
    }

    /// Stops admission before detaching handles. Callers may await the returned
    /// stable snapshot while attempts to schedule replacement work are rejected.
    func quiesce() -> Drain {
        isAccepting = false
        currentGeneration = nil
        let tasks = handles.values.map(\.task)
        handles.removeAll(keepingCapacity: false)
        tasks.forEach { $0.cancel() }
        // Bypass the cap here: `cleanup()` discards this Drain without awaiting
        // it, so a queued continuation would otherwise leak; the drained tasks
        // are being discarded via `canPublish` anyway.
        releaseQueuedReloadSlotWaiters()
        return Drain(tasks: tasks)
    }

    private func finish(_ ticket: Ticket) {
        guard handles[ticket.path]?.ticket.token == ticket.token else { return }
        handles.removeValue(forKey: ticket.path)
    }

    // MARK: - Concurrency cap

    /// Suspends until fewer than `maxConcurrentReloads` reloads are running.
    /// FIFO via `reloadWaiters`; MainActor-only state, so no lock needed.
    private func acquireReloadSlot() async {
        guard activeReloadCount >= Self.maxConcurrentReloads else {
            activeReloadCount += 1
            return
        }
        await withCheckedContinuation { reloadWaiters.append($0) }
    }

    /// Hands the freed slot straight to the next waiter (count unchanged), or
    /// returns it to the pool when no one is waiting.
    private func releaseReloadSlot() {
        guard reloadWaiters.isEmpty else {
            reloadWaiters.removeFirst().resume()
            return
        }
        activeReloadCount -= 1
    }

    private func releaseQueuedReloadSlotWaiters() {
        guard !reloadWaiters.isEmpty else { return }
        let waiters = reloadWaiters
        reloadWaiters.removeAll(keepingCapacity: false)
        activeReloadCount += waiters.count
        waiters.forEach { $0.resume() }
    }

    // MARK: - Burst diagnostics

    /// Coalesces same-tick submissions: callers dispatch reloads synchronously
    /// in a loop, so this `Task` only runs once that loop yields, seeing the
    /// whole burst rather than the first path.
    private func noteBurstDispatch(generation: Int) {
        burstDispatchCount += 1
        burstLogGeneration = generation
        guard !burstLogScheduled else { return }
        burstLogScheduled = true
        Task { @MainActor [weak self] in
            self?.flushBurstLog()
        }
    }

    private func flushBurstLog() {
        let count = burstDispatchCount
        let generation = burstLogGeneration
        burstDispatchCount = 0
        burstLogGeneration = 0
        burstLogScheduled = false
        guard count >= Self.burstLogThreshold else { return }
        Logger.notice(
            "[WPE.texture-cache] burst reload dispatch count=\(count) generation=\(generation)",
            category: .wpeRender
        )
    }
}
#endif
