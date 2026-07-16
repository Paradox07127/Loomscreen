import Foundation

/// One-way application lifecycle gate plus ownership of work intentionally
/// deferred past launch. Keeping delayed tasks in one registry makes quit
/// synchronous from the producer side: cancellation happens before render and
/// persistence teardown, and every queued UI/notification entry rechecks the
/// same state after its suspension.
@MainActor
final class ApplicationLifecycleController {
    enum State: Equatable {
        case idle
        case waitingForTermination
        case replied
    }

    enum TerminationRequest: Equatable {
        case begin
        case wait
        case terminateNow
    }

    private(set) var state: State = .idle
    private var deferredTasks: [UUID: Task<Void, Never>] = [:]

    var allowsWork: Bool { state == .idle }
    var pendingTaskCount: Int { deferredTasks.count }

    @discardableResult
    func schedule(
        after delay: Duration = .zero,
        operation: @MainActor @escaping () async -> Void
    ) -> Bool {
        guard allowsWork else { return false }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard let self, self.allowsWork else { return }
            await operation()
            self.deferredTasks[id] = nil
        }
        deferredTasks[id] = task
        return true
    }

    func beginTermination() -> TerminationRequest {
        switch state {
        case .idle:
            state = .waitingForTermination
            cancelDeferredTasks()
            return .begin
        case .waitingForTermination:
            return .wait
        case .replied:
            return .terminateNow
        }
    }

    @discardableResult
    func markReplied() -> Bool {
        guard state == .waitingForTermination else { return false }
        state = .replied
        return true
    }

    private func cancelDeferredTasks() {
        let tasks = Array(deferredTasks.values)
        deferredTasks.removeAll()
        tasks.forEach { $0.cancel() }
    }
}
