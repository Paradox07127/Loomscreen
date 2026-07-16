#if !LITE_BUILD
import Foundation

protocol WPEMetalTextureUploadExecuting: Sendable {
    func execute(_ operation: @escaping @Sendable () -> Void)
}

private final class WPEMetalTextureDispatchExecutor: WPEMetalTextureUploadExecuting, @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
    }

    func execute(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

/// Bounded off-main upload lane for Metal texture work. WPE scenes routinely
/// ship 4K BC mip chains; running `MTLTexture.replace(...)` on the calling
/// actor blocks the main thread for tens of milliseconds per mip. Admission is
/// gated BEFORE dispatching (suspending the caller, not a GCD worker) so excess
/// uploads wait as continuations instead of parked threads — blocking a
/// semaphore inside a concurrent queue is the classic thread-explosion
/// antipattern. Overcommitting the GPU's IO surface produces no real speedup
/// anyway and just contends for system RAM.
final class WPEMetalTextureUploadQueue: @unchecked Sendable {
    struct AdmissionSnapshot: Equatable, Sendable {
        let grantedCount: Int
        let waitingCount: Int
    }

    /// Capped at half the active core count (min 1, max 2) so a 6-display setup
    /// never stalls the GPU on a single mip; the bound is purely heuristic.
    static let shared = WPEMetalTextureUploadQueue(
        label: "com.livewallpaper.wpe-metal.texture-upload",
        maxConcurrentUploads: max(1, min(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    )

    /// Suspension-based counting semaphore (the AsyncSemaphore pattern).
    /// Cancellation and slot grants share one lock, so a cancelled waiter is
    /// removed before it can reach the synchronous upload queue.
    private final class AsyncAdmission: @unchecked Sendable {
        private final class Request: @unchecked Sendable {
            let id = UUID()

            private let lock = NSLock()
            private var cancellationRequested = false

            var isCancellationRequested: Bool {
                lock.lock()
                defer { lock.unlock() }
                return cancellationRequested
            }

            func cancel() {
                lock.lock()
                cancellationRequested = true
                lock.unlock()
            }
        }

        fileprivate final class Permit: @unchecked Sendable {
            private let lock = NSLock()
            private let admission: AsyncAdmission
            private let requestID: UUID
            private var isReleased = false

            init(admission: AsyncAdmission, requestID: UUID) {
                self.admission = admission
                self.requestID = requestID
            }

            func release() {
                lock.lock()
                guard !isReleased else {
                    lock.unlock()
                    return
                }
                isReleased = true
                lock.unlock()
                admission.release(requestID: requestID)
            }

            deinit {
                release()
            }
        }

        private struct Waiter {
            let request: Request
            let continuation: CheckedContinuation<Void, Error>
        }

        private let lock = NSLock()
        private var availableSlots: Int
        private var waiterOrder: [UUID] = []
        private var waiters: [UUID: Waiter] = [:]
        private var grantedRequestIDs: Set<UUID> = []
        private let didUpdate: (@Sendable (AdmissionSnapshot) -> Void)?

        init(
            slots: Int,
            didUpdate: (@Sendable (AdmissionSnapshot) -> Void)?
        ) {
            availableSlots = max(slots, 1)
            self.didUpdate = didUpdate
        }

        fileprivate func acquire() async throws -> Permit {
            let request = Request()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    register(request, continuation: continuation)
                }
            } onCancel: {
                request.cancel()
                self.cancel(request)
            }

            let permit = Permit(admission: self, requestID: request.id)
            if request.isCancellationRequested {
                permit.release()
                throw CancellationError()
            }
            return permit
        }

        private func register(
            _ request: Request,
            continuation: CheckedContinuation<Void, Error>
        ) {
            let shouldResume: Bool
            let shouldCancel: Bool
            let snapshot: AdmissionSnapshot
            lock.lock()
            if request.isCancellationRequested {
                shouldResume = false
                shouldCancel = true
            } else if availableSlots > 0 {
                availableSlots -= 1
                grantedRequestIDs.insert(request.id)
                shouldResume = true
                shouldCancel = false
            } else {
                waiterOrder.append(request.id)
                waiters[request.id] = Waiter(request: request, continuation: continuation)
                shouldResume = false
                shouldCancel = false
            }
            snapshot = snapshotLocked()
            lock.unlock()
            didUpdate?(snapshot)

            if shouldCancel {
                continuation.resume(throwing: CancellationError())
            } else if shouldResume {
                continuation.resume()
            }
        }

        private func cancel(_ request: Request) {
            let continuation: CheckedContinuation<Void, Error>?
            let snapshot: AdmissionSnapshot
            lock.lock()
            if let waiter = waiters.removeValue(forKey: request.id) {
                waiterOrder.removeAll { $0 == request.id }
                continuation = waiter.continuation
            } else {
                // A granted request is released by its permit. If cancellation
                // won before registration, `register` observes Request's flag.
                continuation = nil
            }
            snapshot = snapshotLocked()
            lock.unlock()
            didUpdate?(snapshot)
            continuation?.resume(throwing: CancellationError())
        }

        private func release(requestID: UUID) {
            var cancelledContinuations: [CheckedContinuation<Void, Error>] = []
            var nextContinuation: CheckedContinuation<Void, Error>?
            let snapshot: AdmissionSnapshot

            lock.lock()
            guard grantedRequestIDs.remove(requestID) != nil else {
                lock.unlock()
                return
            }
            while !waiterOrder.isEmpty {
                let nextID = waiterOrder.removeFirst()
                guard let waiter = waiters.removeValue(forKey: nextID) else { continue }
                if waiter.request.isCancellationRequested {
                    cancelledContinuations.append(waiter.continuation)
                    continue
                }
                grantedRequestIDs.insert(nextID)
                nextContinuation = waiter.continuation
                break
            }
            if nextContinuation == nil {
                availableSlots += 1
            }
            snapshot = snapshotLocked()
            lock.unlock()

            didUpdate?(snapshot)
            cancelledContinuations.forEach { $0.resume(throwing: CancellationError()) }
            nextContinuation?.resume()
        }

        var snapshot: AdmissionSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return snapshotLocked()
        }

        private func snapshotLocked() -> AdmissionSnapshot {
            AdmissionSnapshot(
                grantedCount: grantedRequestIDs.count,
                waitingCount: waiters.count
            )
        }
    }

    /// Cancellation can race the handoff from Swift concurrency to GCD. The
    /// locked `tryBegin` transition defines which side won: if cancellation
    /// wins, synchronous Metal work is skipped; if upload wins, it may finish
    /// but its value is discarded.
    private final class OperationCancellationState: @unchecked Sendable {
        private enum Phase {
            case pending
            case running
            case cancelled
            case finished
        }

        private let lock = NSLock()
        private var phase: Phase = .pending

        func cancel() {
            lock.lock()
            if phase == .pending || phase == .running {
                phase = .cancelled
            }
            lock.unlock()
        }

        func tryBegin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard phase == .pending else { return false }
            phase = .running
            return true
        }

        /// Returns true only when completion wins the race with cancellation.
        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard phase == .running else { return false }
            phase = .finished
            return true
        }
    }

    private let executor: any WPEMetalTextureUploadExecuting
    private let admission: AsyncAdmission
    private let didStartUpload: (@Sendable (Bool) -> Void)?

    init(
        label: String,
        maxConcurrentUploads: Int,
        didStartUpload: (@Sendable (Bool) -> Void)? = nil,
        didUpdateAdmission: (@Sendable (AdmissionSnapshot) -> Void)? = nil,
        executor: (any WPEMetalTextureUploadExecuting)? = nil
    ) {
        self.executor = executor ?? WPEMetalTextureDispatchExecutor(label: label)
        admission = AsyncAdmission(
            slots: maxConcurrentUploads,
            didUpdate: didUpdateAdmission
        )
        self.didStartUpload = didStartUpload
    }

    var admissionSnapshot: AdmissionSnapshot {
        admission.snapshot
    }

    func perform<T>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let cancellationState = OperationCancellationState()
        return try await withTaskCancellationHandler {
            let permit = try await admission.acquire()
            defer { permit.release() }
            try Task.checkCancellation()

            return try await withCheckedThrowingContinuation { continuation in
                executor.execute {
                    guard cancellationState.tryBegin() else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.didStartUpload?(Thread.isMainThread)
                    do {
                        let value = try operation()
                        if cancellationState.finish() {
                            continuation.resume(returning: value)
                        } else {
                            continuation.resume(throwing: CancellationError())
                        }
                    } catch {
                        if cancellationState.finish() {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(throwing: CancellationError())
                        }
                    }
                }
            }
        } onCancel: {
            cancellationState.cancel()
        }
    }
}
#endif
