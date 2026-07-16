import Foundation

/// Ordered application-termination barrier.
///
/// Render/UI teardown happens synchronously before this coordinator is entered.
/// The async phase must then stop every producer before either persistence
/// system takes its final snapshot: otherwise a tailer can advance a cursor (or
/// a late UI callback can enqueue settings) after the supposedly final flush.
enum AppTerminationCoordinator {
    typealias AsyncStep = @Sendable () async -> Void
    typealias BlockingStep = @Sendable () -> Void

    static func shutdownForApplication() async {
        await run(
            stopMonitorProducers: { await MonitorRuntime.shared.shutdown() },
            flushMonitorCursors: {
                await runBlockingOffMainActor {
                    MonitorSourceRegistration.flushCursorStoreForTermination()
                }
            },
            flushSettings: { await SettingsManager.shared.flushPendingConfigurationWrites() }
        )
    }

    /// Cursor persistence is synchronous by design so termination can wait for
    /// the exact committed revision. Run that blocking JSON/atomic-file work on
    /// a utility dispatch queue so it neither occupies MainActor nor a Swift
    /// cooperative-pool worker while the writer lock or filesystem stalls.
    static func runBlockingOffMainActor(_ operation: @escaping BlockingStep) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                operation()
                continuation.resume()
            }
        }
    }

    /// Injectable ordering seam used by lifecycle tests. Keeping the sequencing
    /// here (instead of open-coded in AppDelegate) makes the happens-before
    /// contract explicit and independently testable.
    static func run(
        stopMonitorProducers: AsyncStep,
        flushMonitorCursors: AsyncStep,
        flushSettings: AsyncStep
    ) async {
        await stopMonitorProducers()
        await flushMonitorCursors()
        await flushSettings()
    }
}
