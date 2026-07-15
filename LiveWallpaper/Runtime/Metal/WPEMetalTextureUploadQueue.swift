#if !LITE_BUILD
import Foundation

/// Bounded off-main upload lane for Metal texture work. WPE scenes routinely
/// ship 4K BC mip chains; running `MTLTexture.replace(...)` on the calling
/// actor blocks the main thread for tens of milliseconds per mip. Admission is
/// gated BEFORE dispatching (suspending the caller, not a GCD worker) so excess
/// uploads wait as continuations instead of parked threads — blocking a
/// semaphore inside a concurrent queue is the classic thread-explosion
/// antipattern. Overcommitting the GPU's IO surface produces no real speedup
/// anyway and just contends for system RAM.
final class WPEMetalTextureUploadQueue: @unchecked Sendable {
    /// Capped at half the active core count (min 1, max 2) so a 6-display setup
    /// never stalls the GPU on a single mip; the bound is purely heuristic.
    static let shared = WPEMetalTextureUploadQueue(
        label: "com.livewallpaper.wpe-metal.texture-upload",
        maxConcurrentUploads: max(1, min(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    )

    /// Suspension-based counting semaphore (the AsyncSemaphore pattern):
    /// `acquire()` suspends the caller when no slot is free and `release()`
    /// resumes the oldest waiter. No thread ever blocks while waiting.
    private final class AsyncAdmission: @unchecked Sendable {
        private let lock = NSLock()
        private var availableSlots: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(slots: Int) {
            availableSlots = max(slots, 1)
        }

        func acquire() async {
            if tryAcquireSlot() {
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                enqueue(continuation)
            }
        }

        private func tryAcquireSlot() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard availableSlots > 0 else { return false }
            availableSlots -= 1
            return true
        }

        private func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            // Re-check under the lock: a release may have freed a slot between
            // the failed fast path and this registration.
            if availableSlots > 0 {
                availableSlots -= 1
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }

        func release() {
            lock.lock()
            guard !waiters.isEmpty else {
                availableSlots += 1
                lock.unlock()
                return
            }
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }

    private let queue: DispatchQueue
    private let admission: AsyncAdmission
    private let didStartUpload: (@Sendable (Bool) -> Void)?

    init(
        label: String,
        maxConcurrentUploads: Int,
        didStartUpload: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
        self.admission = AsyncAdmission(slots: maxConcurrentUploads)
        self.didStartUpload = didStartUpload
    }

    func perform<T>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        await admission.acquire()
        defer { admission.release() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.didStartUpload?(Thread.isMainThread)
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif
