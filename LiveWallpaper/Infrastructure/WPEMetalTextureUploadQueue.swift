#if !LITE_BUILD
import Foundation

/// Bounded off-main upload lane for Metal texture work. WPE scenes routinely
/// ship 4K BC mip chains; running `MTLTexture.replace(...)` on the calling
/// actor blocks the main thread for tens of milliseconds per mip and stalls
/// SwiftUI updates on multi-display setups. This queue dispatches uploads to
/// a concurrent `DispatchQueue` while a `DispatchSemaphore` caps how many
/// run in parallel — overcommitting the GPU's IO surface produces no real
/// speedup and just contends for system RAM.
final class WPEMetalTextureUploadQueue: @unchecked Sendable {
    /// Process-wide upload lane shared by every renderer instance. Capped at
    /// half the active core count (min 1, max 2) so a 6-display setup never
    /// stalls the GPU on a single mip; the bound is purely heuristic and can
    /// be revisited once Phase 2D ships full uniform binding instrumentation.
    static let shared = WPEMetalTextureUploadQueue(
        label: "com.livewallpaper.wpe-metal.texture-upload",
        maxConcurrentUploads: max(1, min(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    )

    private let queue: DispatchQueue
    private let semaphore: DispatchSemaphore
    private let didStartUpload: (@Sendable (Bool) -> Void)?

    init(
        label: String,
        maxConcurrentUploads: Int,
        didStartUpload: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
        self.semaphore = DispatchSemaphore(value: max(maxConcurrentUploads, 1))
        self.didStartUpload = didStartUpload
    }

    func perform<T>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.semaphore.wait()
                defer { self.semaphore.signal() }
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
