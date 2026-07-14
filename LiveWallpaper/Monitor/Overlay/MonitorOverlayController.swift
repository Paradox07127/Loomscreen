import AppKit
import LiveWallpaperCore
import os

/// App-wide owner of the Monitor widget board as an OVERLAY layer — one floating
/// panel per display, hosting the same native `MonitorBoardHostView` the wallpaper
/// uses, but layered over whatever wallpaper the display shows. Independent of the
/// wallpaper type entirely.
///
/// Modeled on `MonitorHUDController`: it holds ONE shared `MonitorRuntime` lease
/// while any overlay is active (options = union of every overlay's placed widget
/// kinds) and pumps the newest snapshot to every board host at 1 Hz. `ScreenManager`
/// drives it — calling `apply(...)` per screen when a config lands or displays
/// change, and wiring `onOverlayEdited` to persist board edits back into
/// `ScreenConfiguration.monitorOverlay`.
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
        /// The gated board currently shown (never carries agent widgets when the
        /// catalog is locked) — drives the union sampling options.
        var config: MonitorBoardConfiguration
        var agentFleetEnabled: Bool

        init(window: MonitorOverlayWindow, board: MonitorBoardHostView, config: MonitorBoardConfiguration, agentFleetEnabled: Bool) {
            self.window = window
            self.board = board
            self.config = config
            self.agentFleetEnabled = agentFleetEnabled
        }
    }

    private var hosts: [CGDirectDisplayID: Host] = [:]

    private var pumpTask: Task<Void, Never>?
    private var lastGeneration: UInt64 = 0
    private var owesRuntimeRelease = false
    private let runtimeLeaseID = UUID()

    private override init() { super.init() }

    // MARK: - Per-screen reconcile

    /// Create, update, or tear down the overlay for one display. `overlay == nil`
    /// or `!overlay.enabled` removes it; otherwise the panel is created/updated at
    /// the requested z-plane with the gated board.
    func apply(
        overlay: MonitorOverlayConfiguration?,
        screenID: CGDirectDisplayID,
        screenFrame: NSRect,
        agentFleetEnabled: Bool
    ) {
        guard let overlay, overlay.enabled else {
            teardown(screenID: screenID)
            return
        }

        let gated = MonitorWallpaperView.gatedConfiguration(overlay.board, agentFleetEnabled: agentFleetEnabled)
        // The overlay window covers the full screen frame (menu-bar area
        // included), so the board honours the same top forbidden zone the
        // wallpaper host does — derived identically from the matching NSScreen.
        let topInsetFraction = MonitorWallpaperView.menuBarTopInsetFraction(forFrame: screenFrame)

        if let host = hosts[screenID] {
            host.agentFleetEnabled = agentFleetEnabled
            host.config = gated
            host.window.applyFrame(screenFrame)
            host.window.apply(level: overlay.level)
            host.board.apply(configuration: gated, topInsetFraction: topInsetFraction)
            updateInteractive(host)
            refreshLease()
            return
        }

        MonitorSourceRegistration.registerDefaultFactories()

        let window = MonitorOverlayWindow(screenFrame: screenFrame, level: overlay.level)
        let board = MonitorBoardHostView(
            frame: NSRect(origin: .zero, size: screenFrame.size),
            configuration: gated,
            agentFleetEnabled: agentFleetEnabled,
            topInsetFraction: topInsetFraction
        )
        board.autoresizingMask = [.width, .height]
        board.resetHistory()
        window.contentView = board

        let host = Host(window: window, board: board, config: gated, agentFleetEnabled: agentFleetEnabled)
        hosts[screenID] = host

        board.onConfigurationEdited = { [weak self, weak host] edited in
            guard let self, let host else { return }
            let regated = MonitorWallpaperView.gatedConfiguration(edited, agentFleetEnabled: host.agentFleetEnabled)
            host.config = regated
            self.onOverlayEdited?(screenID, edited)
            // A widget add/remove changes the placed-kind set → repoint sampling.
            self.refreshLease()
        }
        board.onEditingChanged = { [weak self, weak host] _ in
            guard let self, let host else { return }
            self.updateInteractive(host)
        }

        updateInteractive(host)
        window.orderFrontRegardless()

        refreshLease()
        primeHost(host)
    }

    /// Tear down the overlay for one display (display unplugged / overlay disabled).
    func teardown(screenID: CGDirectDisplayID) {
        guard let host = hosts.removeValue(forKey: screenID) else { return }
        host.board.flushPendingEdits()
        host.board.onConfigurationEdited = nil
        host.board.onEditingChanged = nil
        host.window.orderOut(nil)
        refreshLease()
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
        for id in Array(hosts.keys) { teardown(screenID: id) }
    }

    // MARK: - Editing

    /// Enter/exit board edit mode on every active overlay (menu-bar driven). The
    /// board's own Done control exits too; both funnel through `onEditingChanged`,
    /// which restores click-through.
    func setEditing(_ editing: Bool) {
        for host in hosts.values { host.board.setEditing(editing) }
    }

    var isEditing: Bool { hosts.values.contains { $0.board.isEditing } }

    var hasActiveOverlay: Bool { !hosts.isEmpty }

    private func updateInteractive(_ host: Host) {
        // Click-through unless the board is being edited or the user opted the
        // overlay into receiving clicks.
        let interactive = host.board.isEditing || host.config.mouseInteractionEnabled
        host.window.setInteractive(interactive)
        host.board.setMouseInteractionEnabled(interactive)
    }

    // MARK: - Runtime lease + pump

    private func refreshLease() {
        if hosts.isEmpty {
            stopPump()
            releaseRuntime()
            return
        }
        let options = makeOptions()
        if owesRuntimeRelease {
            let leaseID = runtimeLeaseID
            Task { await MonitorRuntime.shared.updateOptions(leaseID: leaseID, options: options) }
        } else {
            owesRuntimeRelease = true
            let leaseID = runtimeLeaseID
            Task { await MonitorRuntime.shared.acquire(leaseID: leaseID, options: options) }
            startPump()
        }
    }

    private func makeOptions() -> MonitorRuntimeOptions {
        var kinds: Set<MonitorWidgetKind> = []
        var anyAgentFleet = false
        var gpuSeconds: Double?
        for host in hosts.values {
            kinds.formUnion(host.config.widgets.map(\.kind))
            anyAgentFleet = anyAgentFleet || host.agentFleetEnabled
            if let s = MonitorWidgetDraft.gpuSampleSeconds(in: host.config.widgets) {
                gpuSeconds = min(gpuSeconds ?? s, s)
            }
        }
        return MonitorRuntimeOptions(
            system: true,
            agents: anyAgentFleet && kinds.contains(.fleet),
            usage: anyAgentFleet && kinds.contains(.usage),
            topProcesses: kinds.contains(.processes),
            activeWidgetKinds: kinds,
            gpuSampleSeconds: gpuSeconds
        )
    }

    private func releaseRuntime() {
        guard owesRuntimeRelease else { return }
        owesRuntimeRelease = false
        let leaseID = runtimeLeaseID
        Task { await MonitorRuntime.shared.release(leaseID: leaseID) }
    }

    private func startPump() {
        pumpTask?.cancel()
        pumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, !self.hosts.isEmpty else { return }
                self.pushLatest(force: false)
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
        guard let update = MonitorRuntime.shared.broker.latest(after: 0) else { return }
        host.board.push(update.snapshot)
    }

    private func pushLatest(force: Bool) {
        let broker = MonitorRuntime.shared.broker
        let after = force ? 0 : lastGeneration
        guard let update = broker.latest(after: after) else { return }
        lastGeneration = update.generation
        for host in hosts.values { host.board.push(update.snapshot) }
    }
}
