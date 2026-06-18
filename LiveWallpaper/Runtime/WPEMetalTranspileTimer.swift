import Foundation

/// Process-wide accumulator for the shader-PREP time that `WPEMetalCompileTimer`
/// does NOT cover: the GLSL preprocessor (`WPEShaderPreprocessor.process`) plus
/// the regex-heavy GLSL→MSL transpile (`WPEShaderTranspiler.translateFragment`,
/// which compiles ~30 `NSRegularExpression` per call). Both run lazily on the
/// FIRST encode of each unique pass, so their cost lands inside the renderer's
/// `render.firstFrame` phase but is invisible to the compile timer (that one only
/// wraps `makeLibrary` + `makeRenderPipelineState`).
///
/// This is the diagnostic that splits the unattributed first-frame CPU floor:
/// if `transpile` + `metal-compile` ≈ the first-frame time, the floor is one-time
/// shader prep (which off-thread pre-warm during the parallel load window would
/// eliminate); if `transpile` is small, the floor is per-pass command encoding
/// (binding/uniform packing) instead, which pre-warm does not touch.
///
/// Same contract as `WPEMetalCompileTimer`: active only while `WPEMetalLoadTiming`
/// is on (production pays nothing), global + monotonic, snapshot-and-diff at first
/// frame rather than reset. Concurrent loads over-count; acceptable for an opt-in
/// diagnostic exercised one scene at a time.
enum WPEMetalTranspileTimer {
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
