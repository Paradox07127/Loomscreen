import AppKit
import LiveWallpaperCore
import os

struct MonitorOverlayVisibilityInput: Equatable, Sendable {
    var screenID: CGDirectDisplayID
    var level: MonitorOverlayLevel
    var isDesktopOccluded: Bool
}

struct MonitorOverlayVisibilityDecision: Equatable, Sendable {
    enum RuntimeDisposition: Equatable, Sendable {
        case released
        case paused
        case active
    }

    var runtimeDisposition: RuntimeDisposition
    var visibleHostIDs: Set<CGDirectDisplayID>
    var suspendedHostIDs: Set<CGDirectDisplayID>

    var pumpShouldRun: Bool {
        !visibleHostIDs.isEmpty
    }

    var snapshotRecipientIDs: Set<CGDirectDisplayID> {
        visibleHostIDs
    }
}

/// Pure visibility policy shared by the live controller and characterization tests.
enum MonitorOverlayVisibilityPolicy {
    static func resolve(
        hosts: [MonitorOverlayVisibilityInput],
        isUserAbsent: Bool
    ) -> MonitorOverlayVisibilityDecision {
        guard !hosts.isEmpty else {
            return MonitorOverlayVisibilityDecision(
                runtimeDisposition: .released,
                visibleHostIDs: [],
                suspendedHostIDs: []
            )
        }

        let allHostIDs = Set(hosts.map(\.screenID))
        guard !isUserAbsent else {
            return MonitorOverlayVisibilityDecision(
                runtimeDisposition: .paused,
                visibleHostIDs: [],
                suspendedHostIDs: allHostIDs
            )
        }

        let visibleHostIDs = Set(hosts.compactMap { host -> CGDirectDisplayID? in
            switch host.level {
            case .desktop:
                return host.isDesktopOccluded ? nil : host.screenID
            case .front:
                return host.screenID
            }
        })
        return MonitorOverlayVisibilityDecision(
            runtimeDisposition: visibleHostIDs.isEmpty ? .paused : .active,
            visibleHostIDs: visibleHostIDs,
            suspendedHostIDs: allHostIDs.subtracting(visibleHostIDs)
        )
    }
}

/// Owns one monitor-widget overlay panel per display.
@MainActor
final class MonitorOverlayController: NSObject {
    static let shared = MonitorOverlayController()

    private static let log = os.Logger(subsystem: "com.livewallpaper", category: "MonitorOverlay")

    /// Persisted board edits made on an overlay flow back here so `ScreenManager`
    /// can store them into the screen's `monitorOverlay.board`.
    var onOverlayEdited: ((CGDirectDisplayID, MonitorBoardConfiguration) -> Void)?

    private final class Host {
        let window: MonitorOverlayWindow
        let board: MonitorBoardHostView
        /// The board currently shown — drives the union sampling options.
        var config: MonitorBoardConfiguration
        var level: MonitorOverlayLevel
        var isVisible = false
        var isDeliveringSnapshots = false

        init(
            window: MonitorOverlayWindow,
            board: MonitorBoardHostView,
            config: MonitorBoardConfiguration,
            level: MonitorOverlayLevel
        ) {
            self.window = window
            self.board = board
            self.config = config
            self.level = level
        }
    }

    private var hosts: [CGDirectDisplayID: Host] = [:]
    private var isUserAbsent = false
    private var occludedScreenIDs: Set<CGDirectDisplayID> = []
    private var visibilityDecision = MonitorOverlayVisibilityPolicy.resolve(
        hosts: [],
        isUserAbsent: false
    )

    private var pumpTask: Task<Void, Never>?
    private var lastGeneration: UInt64 = 0
    private let runtime: MonitorRuntime
    private let runtimeLeaseSlot: MonitorRuntimeLeaseSlot

    private struct AppliedRuntimeState {
        var lease: MonitorRuntimeLeaseHandle?
        var isPaused = false
        var options: MonitorRuntimeOptions?
    }

    private enum DesiredRuntimeState {
        case released
        case paused
        case active(MonitorRuntimeOptions)
    }

    private var appliedRuntimeState = AppliedRuntimeState()
    private var runtimeReconciliationRevision: UInt64 = 0
    private var runtimeReconciliationTask: Task<Void, Never>?

    override private convenience init() {
        self.init(runtime: .shared)
    }

    init(runtime: MonitorRuntime) {
        self.runtime = runtime
        self.runtimeLeaseSlot = runtime.makeLeaseSlot()
        super.init()
    }

    // MARK: - Per-screen reconcile

    /// Create, update, or tear down the overlay for one display.
    func apply(
        overlay: MonitorOverlayConfiguration?,
        screenID: CGDirectDisplayID,
        screenFrame: NSRect
    ) {
        guard let overlay, overlay.enabled else {
            teardown(screenID: screenID)
            return
        }

        let topInsetFraction = MonitorWallpaperView.menuBarTopInsetFraction(forFrame: screenFrame)

        if let host = hosts[screenID] {
            host.config = overlay.board
            host.level = overlay.level
            host.window.applyFrame(screenFrame)
            host.window.apply(level: overlay.level)
            host.board.apply(configuration: overlay.board, topInsetFraction: topInsetFraction)
            updateInteractive(host)
            reconcileVisibilityAndRuntime()
            return
        }

        MonitorSourceRegistration.registerDefaultFactories()

        let window = MonitorOverlayWindow(screenFrame: screenFrame, level: overlay.level)
        let board = MonitorBoardHostView(
            frame: NSRect(origin: .zero, size: screenFrame.size),
            configuration: overlay.board,
            topInsetFraction: topInsetFraction
        )
        board.autoresizingMask = [.width, .height]
        board.resetHistory()
        // Every new host starts parked.
        board.setSuspended(true)
        window.contentView = board

        let host = Host(
            window: window,
            board: board,
            config: overlay.board,
            level: overlay.level
        )
        hosts[screenID] = host

        board.onConfigurationEdited = { [weak self, weak host] edited in
            guard let self, let host else { return }
            host.config = edited
            onOverlayEdited?(screenID, edited)
            reconcileVisibilityAndRuntime()
        }
        board.onEditingChanged = { [weak self, weak host] _ in
            guard let self, let host else { return }
            updateInteractive(host)
        }

        updateInteractive(host)
        reconcileVisibilityAndRuntime()
        window.orderFrontRegardless()
    }

    /// Tear down the overlay for one display (display unplugged / overlay disabled).
    func teardown(screenID: CGDirectDisplayID) {
        guard let host = hosts.removeValue(forKey: screenID) else { return }
        host.board.flushPendingEdits()
        host.board.onConfigurationEdited = nil
        host.board.onEditingChanged = nil
        host.window.orderOut(nil)
        reconcileVisibilityAndRuntime()
    }

    /// Tear down overlays for any display not in `liveScreenIDs` (display set
    /// changed). `ScreenManager` calls this alongside per-screen `apply(...)`.
    func retainOnly(_ liveScreenIDs: Set<CGDirectDisplayID>) {
        // Snapshot keys first — `teardown` mutates `hosts`, which would be a
        // mutate-while-iterating crash on the live key view.
        for id in Array(hosts.keys) where !liveScreenIDs.contains(id) {
            teardown(screenID: id)
        }
    }

    func teardownAll() {
        for id in Array(hosts.keys) {
            teardown(screenID: id)
        }
    }

    /// Re-evaluate retained hosts from ScreenManager's current lifecycle and detector snapshot.
    func updateVisibility(
        isUserAbsent: Bool,
        occludedScreenIDs: Set<CGDirectDisplayID>
    ) {
        guard self.isUserAbsent != isUserAbsent
            || self.occludedScreenIDs != occludedScreenIDs else { return }
        self.isUserAbsent = isUserAbsent
        self.occludedScreenIDs = occludedScreenIDs
        reconcileVisibilityAndRuntime()
    }

    // MARK: - Editing

    /// Enter/exit board edit mode on every active overlay (menu-bar driven).
    func setEditing(_ editing: Bool) {
        for host in hosts.values {
            host.board.setEditing(editing)
        }
    }

    var isEditing: Bool {
        hosts.values.contains { $0.board.isEditing }
    }

    var hasActiveOverlay: Bool {
        !hosts.isEmpty
    }

    func waitUntilRuntimeSettled() async {
        let task = runtimeReconciliationTask
        await task?.value
    }

    private func updateInteractive(_ host: Host) {
        let interactive = host.board.isEditing || host.config.mouseInteractionEnabled
        host.window.setInteractive(interactive)
        host.board.setMouseInteractionEnabled(interactive)
    }

    // MARK: - Runtime lease + pump

    private func reconcileVisibilityAndRuntime() {
        let inputs = hosts.map { screenID, host in
            MonitorOverlayVisibilityInput(
                screenID: screenID,
                level: host.level,
                isDesktopOccluded: occludedScreenIDs.contains(screenID)
            )
        }
        let decision = MonitorOverlayVisibilityPolicy.resolve(
            hosts: inputs,
            isUserAbsent: isUserAbsent
        )
        visibilityDecision = decision

        // Suspension is applied immediately on the MainActor so an occluded or absent board cannot animate or receive another pump tick while the actor-side lease transition is awaiting its turn.
        for (screenID, host) in hosts {
            host.isVisible = decision.visibleHostIDs.contains(screenID)
            if !host.isVisible {
                host.isDeliveringSnapshots = false
                host.board.setSuspended(true)
            }
        }
        if !decision.pumpShouldRun {
            stopPump()
        }

        scheduleRuntimeReconciliation()
    }

    private func makeOptions(visibleHostIDs: Set<CGDirectDisplayID>) -> MonitorRuntimeOptions {
        var kinds: Set<MonitorWidgetKind> = []
        var gpuSeconds: Double?
        for (screenID, host) in hosts where visibleHostIDs.contains(screenID) {
            kinds.formUnion(host.config.widgets.map(\.kind))
            if let s = MonitorWidgetDraft.gpuSampleSeconds(in: host.config.widgets) {
                gpuSeconds = min(gpuSeconds ?? s, s)
            }
        }
        return MonitorRuntimeOptions(
            system: MonitorWallpaperView.requiresSystemMetrics(for: kinds),
            agents: kinds.contains(.fleet),
            usage: kinds.contains(.usage),
            topProcesses: kinds.contains(.processes),
            activeWidgetKinds: kinds,
            gpuSampleSeconds: gpuSeconds
        )
    }

    private func scheduleRuntimeReconciliation() {
        runtimeReconciliationRevision &+= 1
        guard runtimeReconciliationTask == nil else { return }
        runtimeReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await runRuntimeReconciliationLoop()
        }
    }

    /// The only path that mutates this controller's MonitorRuntime lease.
    private func runRuntimeReconciliationLoop() async {
        while true {
            let revision = runtimeReconciliationRevision
            let desiredState = desiredRuntimeState()
            await applyRuntimeState(desiredState)

            guard revision == runtimeReconciliationRevision else { continue }
            applyDeliveryState()
            runtimeReconciliationTask = nil
            return
        }
    }

    private func desiredRuntimeState() -> DesiredRuntimeState {
        switch visibilityDecision.runtimeDisposition {
        case .released:
            .released
        case .paused:
            .paused
        case .active:
            .active(makeOptions(visibleHostIDs: visibilityDecision.visibleHostIDs))
        }
    }

    private func applyRuntimeState(_ desiredState: DesiredRuntimeState) async {
        switch desiredState {
        case .released:
            guard let lease = appliedRuntimeState.lease else { return }
            await lease.release().value
            appliedRuntimeState = AppliedRuntimeState()

        case .paused:
            guard let lease = appliedRuntimeState.lease,
                  !appliedRuntimeState.isPaused else { return }
            await lease.setPaused(true).value
            appliedRuntimeState.isPaused = true

        case let .active(options):
            if appliedRuntimeState.lease == nil {
                let lease = runtimeLeaseSlot.acquire(options: options)
                await lease.waitUntilSettled()
                appliedRuntimeState.lease = lease
                appliedRuntimeState.isPaused = false
                appliedRuntimeState.options = options
                return
            }

            guard let lease = appliedRuntimeState.lease else { return }

            if appliedRuntimeState.options != options {
                await lease.updateOptions(options).value
                appliedRuntimeState.options = options
            }
            if appliedRuntimeState.isPaused {
                await lease.setPaused(false).value
                appliedRuntimeState.isPaused = false
            }
        }
    }

    /// Delivery is enabled only after the matching runtime state has applied.
    /// Hidden boards were already suspended synchronously before any actor await.
    private func applyDeliveryState() {
        var newlyVisibleHosts: [Host] = []
        for host in hosts.values {
            let shouldDeliver = host.isVisible
            if shouldDeliver, !host.isDeliveringSnapshots {
                host.isDeliveringSnapshots = true
                host.board.setSuspended(false)
                newlyVisibleHosts.append(host)
            } else if !shouldDeliver {
                host.isDeliveringSnapshots = false
                host.board.setSuspended(true)
            }
        }

        if hosts.values.contains(where: \.isDeliveringSnapshots) {
            startPump()
        } else {
            stopPump()
        }
        for host in newlyVisibleHosts {
            primeHost(host)
        }
    }

    private func startPump() {
        guard pumpTask == nil else { return }
        pumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      hosts.values.contains(where: \.isDeliveringSnapshots) else { return }
                pushLatest(force: false)
            }
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    /// Push the current newest snapshot into a freshly-added host so it paints
    /// immediately instead of waiting for the next generation bump.
    private func primeHost(_ host: Host) {
        guard host.isVisible, host.isDeliveringSnapshots else { return }
        guard let update = runtime.broker.latest(after: 0) else { return }
        host.board.push(update.snapshot)
    }

    private func pushLatest(force: Bool) {
        let broker = runtime.broker
        let after = force ? 0 : lastGeneration
        guard let update = broker.latest(after: after) else { return }
        lastGeneration = update.generation
        for host in hosts.values where host.isVisible && host.isDeliveringSnapshots {
            host.board.push(update.snapshot)
        }
    }
}
