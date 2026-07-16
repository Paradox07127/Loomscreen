import Dispatch
import os

/// Typed process-wide memory-pressure state. The raw value intentionally matches
/// `MonitorSystemSnapshot.memPressure`'s existing wire vocabulary.
enum SystemMemoryPressureLevel: String, CaseIterable, Sendable {
    case normal
    case warning = "warn"
    case critical
}

typealias SystemMemoryPressureChangeHandler = @Sendable (SystemMemoryPressureLevel) -> Void

/// Read-only seam for consumers such as Monitor v2. Reading the app-wide
/// pressure state must not create or retain another kernel dispatch source.
protocol MemoryPressureReading: Sendable {
    func currentLevel() -> SystemMemoryPressureLevel
}

/// Injectable ownership seam for kernel memory-pressure observation.
///
/// Implementations are synchronous and thread-safe. `start(onChange:)` installs
/// at most one callback; callbacks may arrive on an implementation-owned queue,
/// so actor-isolated consumers must explicitly hop to their actor. `stop()` is
/// idempotent but is not a callback barrier: a callback already dequeued by the
/// source may still arrive, so every owner must also invalidate/guard late work.
protocol MemoryPressureWatching: MemoryPressureReading {
    func start(onChange: SystemMemoryPressureChangeHandler?)
    func stop()
}

extension MemoryPressureWatching {
    func start() {
        start(onChange: nil)
    }
}

/// Non-owning default for previews and isolated `ScreenManager` tests. The real
/// app startup plan opts into `SystemMemoryPressureWatcher.shared` explicitly so
/// a test manager cannot permanently cancel the process-wide one-shot source.
struct InactiveMemoryPressureWatcher: MemoryPressureWatching {
    static let shared = InactiveMemoryPressureWatcher()

    func start(onChange _: SystemMemoryPressureChangeHandler?) {}
    func stop() {}
    func currentLevel() -> SystemMemoryPressureLevel { .normal }
}

/// Minimal lifecycle adapter around `DispatchSourceMemoryPressure`. The seam
/// lets tests exercise the production watcher's one-shot lifecycle without
/// manufacturing a real kernel pressure event.
protocol MemoryPressureSourceLifecycle: AnyObject, Sendable {
    var data: DispatchSource.MemoryPressureEvent { get }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void)
    func activate()
    func cancel()
}

private final class DispatchMemoryPressureSourceLifecycle: MemoryPressureSourceLifecycle, @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure

    init() {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(
                label: "com.livewallpaper.system-memory-pressure",
                qos: .utility
            )
        )
    }

    var data: DispatchSource.MemoryPressureEvent {
        source.data
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func activate() {
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}

/// App-wide `DispatchSourceMemoryPressure` owner.
///
/// A dispatch source is a one-shot lifecycle object: the first `start` activates
/// it, `stop` permanently cancels it, and the same instance cannot be restarted.
/// Repeated starts/stops and a start after cancellation are safe no-ops. App code
/// uses only `shared`; the injected source initializer exists for tests.
final class SystemMemoryPressureWatcher: MemoryPressureWatching {
    static let shared = SystemMemoryPressureWatcher {
        DispatchMemoryPressureSourceLifecycle()
    }

    private enum Lifecycle {
        case ready
        case active
        case cancelled
    }

    private struct State {
        var lifecycle = Lifecycle.ready
        var generation: UInt64 = 0
        var level = SystemMemoryPressureLevel.normal
        var onChange: SystemMemoryPressureChangeHandler?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let source: any MemoryPressureSourceLifecycle

    init(sourceFactory: @escaping @Sendable () -> any MemoryPressureSourceLifecycle) {
        let source = sourceFactory()
        self.source = source

        let state = state
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            let nextLevel = Self.level(for: event)
            let delivery: (SystemMemoryPressureChangeHandler?, UInt64)? = state.withLock { state in
                guard state.lifecycle == .active,
                      state.level != nextLevel else { return nil }
                state.level = nextLevel
                return (state.onChange, state.generation)
            }
            guard let (callback, generation) = delivery else { return }
            // Minimize the queued-event race by revalidating immediately before
            // delivery. This cannot make `stop()` a callback barrier: stop may
            // still race after this check, so the owner must reject late work.
            guard state.withLock({ state in
                state.lifecycle == .active && state.generation == generation
            }) else { return }
            callback?(nextLevel)
        }
    }

    deinit {
        stop()
    }

    func start(onChange: SystemMemoryPressureChangeHandler?) {
        state.withLock { state in
            guard state.lifecycle == .ready else { return }
            state.lifecycle = .active
            state.generation &+= 1
            state.onChange = onChange
            source.activate()
        }
    }

    func stop() {
        state.withLock { state in
            switch state.lifecycle {
            case .ready:
                // Activate before cancelling so a never-started dispatch source
                // is not left permanently suspended during destruction.
                state.lifecycle = .cancelled
                state.generation &+= 1
                state.onChange = nil
                source.activate()
                source.cancel()
            case .active:
                state.lifecycle = .cancelled
                state.generation &+= 1
                state.onChange = nil
                source.cancel()
            case .cancelled:
                break
            }
        }
    }

    func currentLevel() -> SystemMemoryPressureLevel {
        state.withLock { $0.level }
    }

    /// Pure precedence rule for a coalesced dispatch event. Dispatch may set more
    /// than one bit; the most severe state must always win.
    static func level(
        for event: DispatchSource.MemoryPressureEvent
    ) -> SystemMemoryPressureLevel {
        if event.contains(.critical) {
            .critical
        } else if event.contains(.warning) {
            .warning
        } else {
            .normal
        }
    }
}
