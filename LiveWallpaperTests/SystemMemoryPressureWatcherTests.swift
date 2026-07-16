import Dispatch
import Foundation
@testable import LiveWallpaper
import os
import Testing

@Suite("System memory-pressure watcher", .serialized)
struct SystemMemoryPressureWatcherTests {
    @Test("Coalesced event precedence is critical then warning then normal")
    func eventPrecedence() {
        #expect(
            SystemMemoryPressureWatcher.level(for: [.normal, .warning, .critical])
                == .critical
        )
        #expect(
            SystemMemoryPressureWatcher.level(for: [.normal, .warning])
                == .warning
        )
        #expect(SystemMemoryPressureWatcher.level(for: [.normal]) == .normal)
        #expect(SystemMemoryPressureWatcher.level(for: []) == .normal)
        #expect(SystemMemoryPressureLevel.warning.rawValue == "warn")
    }

    @Test("Production watcher activates and cancels its injected source exactly once")
    func productionLifecycleContract() {
        let factoryCalls = OSAllocatedUnfairLock(initialState: 0)
        let source = TestMemoryPressureSource()
        let watcher = SystemMemoryPressureWatcher {
            factoryCalls.withLock { $0 += 1 }
            return source
        }
        let received = OSAllocatedUnfairLock(initialState: [SystemMemoryPressureLevel]())

        watcher.start { level in
            received.withLock { $0.append(level) }
        }
        watcher.start { _ in
            Issue.record("a repeated start must not replace the first callback")
        }
        source.emit(.warning)
        watcher.stop()
        watcher.stop()
        watcher.start(onChange: nil)
        source.emit(.critical)

        #expect(factoryCalls.withLock { $0 } == 1)
        #expect(
            source.snapshot()
                == TestMemoryPressureSource.Snapshot(
                    eventHandlerInstallations: 1,
                    activations: 1,
                    cancellations: 1
                )
        )
        #expect(watcher.currentLevel() == .warning)
        #expect(received.withLock { $0 } == [.warning])
    }

    @Test("Production watcher balances a stop before start exactly once")
    func stopBeforeStartContract() {
        let source = TestMemoryPressureSource()
        let watcher = SystemMemoryPressureWatcher { source }

        watcher.stop()
        watcher.stop()
        watcher.start(onChange: nil)
        source.emit(.critical)

        #expect(
            source.snapshot()
                == TestMemoryPressureSource.Snapshot(
                    eventHandlerInstallations: 1,
                    activations: 1,
                    cancellations: 1
                )
        )
        #expect(watcher.currentLevel() == .normal)
    }

    @Test("A source event queued before stop is generation-rejected when delivered later")
    func queuedSourceEventIsRejectedAfterStop() {
        let source = TestMemoryPressureSource()
        let watcher = SystemMemoryPressureWatcher { source }
        let received = OSAllocatedUnfairLock(initialState: [SystemMemoryPressureLevel]())

        watcher.start { level in
            received.withLock { $0.append(level) }
        }
        let queuedEvent = source.prepareQueuedEvent(.critical)
        watcher.stop()
        queuedEvent?()

        #expect(watcher.currentLevel() == .normal)
        #expect(received.withLock { $0 }.isEmpty)
    }

    @Test("App startup owns shared watcher while Monitor uses only its read seam")
    func sharedOwnerSourceContract() throws {
        let runtimeOptions = AppRuntimeOptions(
            arguments: [],
            environment: [:],
            isXCTestLoaded: false
        )
        let options = AppStartupPlan(
            runtimeOptions: runtimeOptions,
            onboardingCompleted: true
        ).screenManagerOptions
        #expect(
            (options.memoryPressureWatcher as? SystemMemoryPressureWatcher)
                === SystemMemoryPressureWatcher.shared
        )
        #expect(
            ScreenManagerStartupOptions(featureCatalog: .unconfigured)
                .memoryPressureWatcher is InactiveMemoryPressureWatcher
        )

        let metricsSource = try productionSource(
            "LiveWallpaper/Monitor/Sources/SystemMetricsSource.swift"
        )
        #expect(
            metricsSource.contains(
                "memoryPressureReader: any MemoryPressureReading = SystemMemoryPressureWatcher.shared"
            )
        )
        #expect(!metricsSource.contains("pressure.start()"))
        #expect(!metricsSource.contains("pressure.stop()"))
    }

    @Test("Monitor pressure wire mapping reads without owning a source")
    func monitorWireMapping() {
        for (level, wireValue) in [
            (SystemMemoryPressureLevel.normal, "normal"),
            (.warning, "warn"),
            (.critical, "critical"),
        ] {
            let reader = StaticMemoryPressureReader(level: level)
            #expect(SystemMetricsSource.memoryPressureWireValue(from: reader) == wireValue)
        }
    }

    private func productionSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private final class TestMemoryPressureSource: MemoryPressureSourceLifecycle {
    struct Snapshot: Equatable {
        var eventHandlerInstallations: Int
        var activations: Int
        var cancellations: Int
    }

    // MemoryPressureEvent isn't Sendable, so the lock stores its rawValue instead.
    private struct State {
        var dataRawValue = DispatchSource.MemoryPressureEvent.normal.rawValue
        var eventHandler: (@Sendable () -> Void)?
        var eventHandlerInstallations = 0
        var activations = 0
        var cancellations = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var data: DispatchSource.MemoryPressureEvent {
        DispatchSource.MemoryPressureEvent(rawValue: state.withLock { $0.dataRawValue })
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { state in
            state.eventHandler = handler
            state.eventHandlerInstallations += 1
        }
    }

    func activate() {
        state.withLock { $0.activations += 1 }
    }

    func cancel() {
        state.withLock { $0.cancellations += 1 }
    }

    func emit(_ event: DispatchSource.MemoryPressureEvent) {
        prepareQueuedEvent(event)?()
    }

    func prepareQueuedEvent(
        _ event: DispatchSource.MemoryPressureEvent
    ) -> (@Sendable () -> Void)? {
        let rawValue = event.rawValue
        return state.withLock { state in
            state.dataRawValue = rawValue
            return state.eventHandler
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { state in
            Snapshot(
                eventHandlerInstallations: state.eventHandlerInstallations,
                activations: state.activations,
                cancellations: state.cancellations
            )
        }
    }
}

private struct StaticMemoryPressureReader: MemoryPressureReading {
    let level: SystemMemoryPressureLevel

    func currentLevel() -> SystemMemoryPressureLevel {
        level
    }
}
