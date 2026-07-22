import AppKit
import Observation
import SwiftUI

/// App-wide owner of the floating fleet HUD capsule.
@MainActor
@Observable
final class MonitorHUDController: NSObject {
    static let shared = MonitorHUDController()

    private static let enabledKey = "monitor.hud.enabled"

    /// Filled by the session router at integration so "Focus" can jump to the blocked session.
    @ObservationIgnored var focusHandler: (@MainActor (String) -> Void)? {
        didSet { store.focusAvailable = focusHandler != nil }
    }

    /// Persisted master switch for the HUD, surfaced as the menu-bar toggle.
    /// Setting it shows/hides the panel immediately.
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            persistEnabled(isEnabled)
            if isEnabled { show() } else { hide() }
        }
    }

    @ObservationIgnored private let persistEnabled: @MainActor (Bool) -> Void

    /// Current derived HUD state; the hosted SwiftUI view reads this.
    @ObservationIgnored private var model: MonitorHUDModel = .empty

    @ObservationIgnored private var panel: MonitorHUDPanel?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var lastGeneration: UInt64 = 0
    @ObservationIgnored private var lastPublishAt: Double?
    @ObservationIgnored private let runtime: MonitorRuntime
    @ObservationIgnored private let runtimeLeaseSlot: MonitorRuntimeLeaseSlot
    @ObservationIgnored private var runtimeLease: MonitorRuntimeLeaseHandle?
    @ObservationIgnored private var lastRuntimeTask: Task<Void, Never>?
    /// Unlike `hide()` (a normal, restartable user action), application
    /// termination is one-way and must reject stale menu/observer callbacks.
    @ObservationIgnored private(set) var isShutdown = false
    /// Backing store the hosted view observes for model changes.
    @ObservationIgnored private let store = HUDModelStore()

    private override convenience init() {
        self.init(initiallyEnabled: UserDefaults.standard.bool(forKey: Self.enabledKey))
    }

    /// Internal initializer keeps lifecycle tests isolated from the shared HUD.
    init(
        initiallyEnabled: Bool,
        runtime: MonitorRuntime = .shared,
        persistEnabled: @MainActor @escaping (Bool) -> Void = {
            UserDefaults.standard.set($0, forKey: MonitorHUDController.enabledKey)
        }
    ) {
        self.runtime = runtime
        self.runtimeLeaseSlot = runtime.makeLeaseSlot()
        self.persistEnabled = persistEnabled
        self.isEnabled = initiallyEnabled
        super.init()
    }

    // MARK: - Public control

    /// Shows the HUD if the persisted switch is on. Safe to call repeatedly
    /// (idempotent) — used by the app-startup hook.
    func applyPersistedStateAtStartup() {
        guard !isShutdown else { return }
        guard isEnabled else { return }
        show()
    }

    func show() {
        guard !isShutdown else { return }
        guard panel == nil else {
            forceRefresh()
            return
        }

        MonitorSourceRegistration.registerDefaultFactories()
        acquireRuntime()

        store.focusAvailable = focusHandler != nil
        let hosting = MonitorHUDHostView(store: store) { [weak self] sessionID in
            self?.focusHandler?(sessionID)
        }
        let panel = MonitorHUDPanel(rootView: hosting)
        panel.delegate = self
        self.panel = panel

        panel.applyInitialPlacement()
        panel.orderFrontRegardless()

        startPump()
        forceRefresh()
    }

    func hide() {
        stopPump()
        releaseRuntime()
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
    }

    /// Permanently closes the HUD for this process while preserving the user's
    /// persisted `isEnabled` preference for the next launch.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        hide()
    }

    var isPresented: Bool { panel != nil }
    var hasActivePump: Bool { pumpTask != nil }
    var hasRuntimeLease: Bool { runtimeLease != nil }

    func waitUntilRuntimeSettled() async {
        if let runtimeLease {
            await runtimeLease.waitUntilSettled()
        } else {
            await lastRuntimeTask?.value
        }
    }

    // MARK: - Runtime lease

    private func acquireRuntime() {
        guard !isShutdown, runtimeLease == nil else { return }
        // Roots stay nil: the runtime resolves security-scoped grants itself so
        // scope lifetime tracks the pipeline, not this controller.
        let options = MonitorRuntimeOptions(system: false, agents: true, usage: false)
        runtimeLease = runtimeLeaseSlot.acquire(options: options)
    }

    private func releaseRuntime() {
        guard let lease = runtimeLease else { return }
        runtimeLease = nil
        lastRuntimeTask = lease.release()
    }

    // MARK: - Data pump (1 Hz, mirrors MonitorWallpaperView)

    private func startPump() {
        pumpTask?.cancel()
        pumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, self.panel != nil else { return }
                self.pullLatest(force: false)
            }
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    private func forceRefresh() {
        pullLatest(force: true)
    }

    /// Pulls the newest snapshot from the broker and recomputes the model.
    private func pullLatest(force: Bool) {
        let broker = runtime.broker
        let now = Date().timeIntervalSince1970

        if let update = broker.latest(after: force ? 0 : lastGeneration) {
            if update.generation != lastGeneration || force {
                lastGeneration = update.generation
                lastPublishAt = now
            }
            model = MonitorHUDModel.make(from: update.snapshot, now: now, lastPublishAt: lastPublishAt)
        } else {
            model = MonitorHUDModel.make(from: nil, now: now, lastPublishAt: lastPublishAt)
        }

        store.model = model
    }
}

// MARK: - NSWindowDelegate (drag persistence)

extension MonitorHUDController: NSWindowDelegate {
    /// Window-background drags settle here; persist the origin so the capsule
    /// restores where the user left it.
    func windowDidMove(_ notification: Notification) {
        panel?.persistCurrentOrigin()
    }
}

// MARK: - Observable bridge for the hosted view

/// Minimal observable box so the SwiftUI capsule re-renders when the controller
/// pushes a new model, without the whole controller crossing into the view.
@MainActor
@Observable
final class HUDModelStore {
    var model: MonitorHUDModel = .empty
    /// Mirrors whether a `focusHandler` is wired so the view can hide the Focus
    /// button until the router fills it.
    var focusAvailable = false
}

/// Thin wrapper that feeds the store's model into `MonitorHUDView` and forwards
/// Focus taps back to the controller's handler.
private struct MonitorHUDHostView: View {
    let store: HUDModelStore
    let onFocus: (String) -> Void

    var body: some View {
        MonitorHUDView(
            model: store.model,
            onFocus: store.focusAvailable ? onFocus : nil
        )
    }
}
