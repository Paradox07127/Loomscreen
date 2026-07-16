#if !LITE_BUILD
import Foundation

/// Generation-scoped owner for on-demand static-texture reload tasks. Admission
/// closes atomically with task detachment, so a reload can drain a stable set.
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

    private var currentGeneration: Int?
    private var handles: [String: Handle] = [:]
    private(set) var isAccepting = false

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
            await operation(ticket)
            self?.finish(ticket)
        }
        handles[path] = Handle(ticket: ticket, task: task)
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
        return Drain(tasks: tasks)
    }

    private func finish(_ ticket: Ticket) {
        guard handles[ticket.path]?.ticket.token == ticket.token else { return }
        handles.removeValue(forKey: ticket.path)
    }
}
#endif
