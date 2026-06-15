import Foundation

/// Process-wide accumulator for Metal shader/pipeline COMPILATION time —
/// `makeLibrary(source:)` (MSL→AIR) plus `makeRenderPipelineState` (pipeline
/// compile). These run lazily on first encode, so their cost lands inside the
/// renderer's `render.firstFrame` phase rather than `pipeline.build`. Measuring
/// them separately tells us how much of the first frame is one-time compilation
/// — which a binary-archive / MSL cache could eliminate — versus genuine GPU
/// work or texture-upload completion.
///
/// Active only while the `WPEMetalLoadTiming` diagnostic is on, so production
/// pays nothing. The accumulator is global + monotonic (compilation happens
/// across the executor's caches and the shader compiler); a renderer snapshots
/// `milliseconds` at load start and reports the delta at first frame rather than
/// resetting — so a concurrent load on another display can't zero it mid-flight.
/// Truly concurrent loads still over-count each other's compiles; acceptable for
/// an opt-in diagnostic usually exercised one scene at a time.
enum WPEMetalCompileTimer {
    private static let lock = NSLock()
    // Manually serialized by `lock`; the unchecked annotation is the idiomatic
    // escape hatch for lock-guarded global state under strict concurrency.
    nonisolated(unsafe) private static var totalNanos: UInt64 = 0

    private static var isActive: Bool {
        UserDefaults.standard.bool(forKey: "WPEMetalLoadTiming")
    }

    /// Times `body` and adds it to the running total when the diagnostic is on;
    /// otherwise calls through with no measurement overhead.
    static func measure<T>(_ body: () throws -> T) rethrows -> T {
        guard isActive else { return try body() }
        let start = DispatchTime.now()
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
            lock.lock()
            totalNanos &+= elapsed
            lock.unlock()
        }
        return try body()
    }

    /// Monotonic running total in milliseconds; callers snapshot + diff it.
    static var milliseconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(totalNanos) / 1_000_000
    }
}
