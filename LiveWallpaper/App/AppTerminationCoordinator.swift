import Foundation

/// Ordered application-termination barrier.
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

    /// Cursor persistence is synchronous by design so termination can wait for the exact committed revision.
    static func runBlockingOffMainActor(_ operation: @escaping BlockingStep) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                operation()
                continuation.resume()
            }
        }
    }

    /// Injectable ordering seam used by lifecycle tests.
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
