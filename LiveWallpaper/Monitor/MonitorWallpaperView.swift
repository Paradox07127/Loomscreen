import AppKit
import LiveWallpaperCore
import os

/// Desktop wallpaper host for the native Monitor v2 widget board.
///
/// This replaces the retired v1 WKWebView dashboard: instead of loading a
/// bundled `dashboard.html` and pushing JSON over a `monitorBridge`, it embeds
/// the native `MonitorBoardHostView` (SwiftUI/CoreAnimation) and feeds it
/// `MonitorSnapshot` values pulled from the shared `MonitorRuntime` broker.
///
/// Responsibilities carried over 1:1 from v1:
///   • Lease the shared data pipeline (unique UUID acquire → single release),
///     now advertising the board's active widget kinds so the runtime only
///     samples what is on screen.
///   • Pump the newest snapshot at the configured cadence, pausing while the
///     performance policy suspends the wallpaper (occlusion / battery / etc.).
///   • Click-through unless `mouseInteractionEnabled` (mirrored by the window's
///     `ignoresMouseEvents`, set alongside in `makeMonitorSession`).
///   • Hard-gate the AI-agent modules: when the injected feature catalog does
///     not unlock `.agentFleet`, usage/fleet placements are stripped before the
///     board ever sees them.
///
/// Board edits (drag/add/remove/resize) surface through `onConfigurationEdited`
/// — the session builder wires that to the same `ScreenManager` config-update
/// path every other wallpaper type uses.
@MainActor
final class MonitorWallpaperView: NSView, WallpaperPerformanceConfigurable, WallpaperResourceCleanable {

    private static let log = os.Logger(subsystem: "com.livewallpaper", category: "MonitorWallpaper")

    private let boardHost: MonitorBoardHostView
    private var configuration: MonitorBoardConfiguration
    /// Whether the injected feature catalog unlocks the AI-agent modules. When
    /// false, usage/fleet placements are stripped before display and the lease
    /// never requests those kinds.
    private let agentFleetEnabled: Bool

    /// Mirrors `configuration.mouseInteractionEnabled`; when false the wallpaper
    /// stays click-through. The window's own `ignoresMouseEvents` is set
    /// alongside this in `makeMonitorSession`, and the board host's own
    /// `hitTest` agrees.
    private var allowMouseInteraction: Bool

    /// Fires (debounced by the board host) whenever the user commits a board
    /// edit; the session builder points this at `ScreenManager`.
    var onConfigurationEdited: ((MonitorBoardConfiguration) -> Void)?

    /// Data pump. `nil` while suspended / torn down.
    private var pumpTask: Task<Void, Never>?
    private var lastGeneration: UInt64 = 0
    private var isSuspended = false
    private var isCleaningUp = false
    /// True once we have issued a matching `MonitorRuntime.acquire` we still owe
    /// a `release` for. Consumed by whichever teardown path runs first
    /// (`cleanup()` or `deinit`) so the shared runtime is released exactly once.
    private var owesRuntimeRelease = false
    /// Identifies this view's runtime lease; the runtime tolerates the release
    /// task overtaking the acquire task as long as both carry this ID.
    private let runtimeLeaseID = UUID()

    init(
        frame frameRect: NSRect,
        configuration: MonitorBoardConfiguration,
        agentFleetEnabled: Bool
    ) {
        self.agentFleetEnabled = agentFleetEnabled
        let gated = Self.gatedConfiguration(configuration, agentFleetEnabled: agentFleetEnabled)
        self.configuration = gated
        self.allowMouseInteraction = gated.mouseInteractionEnabled
        self.boardHost = MonitorBoardHostView(
            frame: NSRect(origin: .zero, size: frameRect.size),
            configuration: gated,
            agentFleetEnabled: agentFleetEnabled,
            topInsetFraction: Self.menuBarTopInsetFraction(forFrame: frameRect)
        )

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        boardHost.frame = bounds
        boardHost.autoresizingMask = [.width, .height]
        addSubview(boardHost)

        // A fresh session starts with clean rolling history so series don't
        // bleed across sessions.
        boardHost.resetHistory()

        // Route committed board edits back out; re-apply the agent gate before
        // persisting so a stripped board can never write fleet/usage back in.
        boardHost.onConfigurationEdited = { [weak self] edited in
            guard let self else { return }
            self.configuration = edited
            self.onConfigurationEdited?(edited)
        }

        // Force mouse interaction on while the board is being edited (both the
        // view's hitTest gate and the window policy), restoring the persisted
        // click-through state on exit — including the board's own Done control.
        boardHost.onEditingChanged = { [weak self] editing in
            self?.handleEditingChanged(editing)
        }

        // Warm the shared pipeline immediately so data is ready by first paint.
        MonitorSourceRegistration.registerDefaultFactories()
        owesRuntimeRelease = true
        let leaseID = runtimeLeaseID
        let options = makeRuntimeOptions()
        Task { await MonitorRuntime.shared.acquire(leaseID: leaseID, options: options) }

        startPump()
        // Paint the current snapshot (if any) immediately.
        pushLatestSnapshot(force: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // Balance the runtime acquire even if `cleanup()` was never called
        // (defensive; the session normally calls it).
        pumpTask?.cancel()
        if owesRuntimeRelease {
            let leaseID = runtimeLeaseID
            Task { await MonitorRuntime.shared.release(leaseID: leaseID) }
        }
    }

    // MARK: - Runtime options

    private func makeRuntimeOptions() -> MonitorRuntimeOptions {
        // The active widget kinds drive on-demand sampling (I1's lease seam):
        // the runtime only samples the metrics some on-screen widget consumes.
        // Agent/usage modules stay hard-gated on `agentFleetEnabled`; the config
        // is already stripped of those placements when the gate is off, so the
        // kind set can't re-enable them.
        let kinds = Set(configuration.widgets.map(\.kind))
        let wantsAgents = agentFleetEnabled && kinds.contains(.fleet)
        let wantsUsage = agentFleetEnabled && kinds.contains(.usage)
        let wantsProcesses = kinds.contains(.processes)
        // Roots stay nil here: the runtime resolves the security-scoped grants
        // itself so scope lifetime matches pipeline (not view) lifetime.
        return MonitorRuntimeOptions(
            system: true,
            agents: wantsAgents,
            usage: wantsUsage,
            topProcesses: wantsProcesses,
            activeWidgetKinds: kinds,
            gpuSampleSeconds: MonitorWidgetDraft.gpuSampleSeconds(in: configuration.widgets)
        )
    }

    /// Repoint the shared lease's on-demand sampling for a live config change.
    /// Uses the non-creating `updateOptions` (not `acquire`) under the same lease
    /// ID, so this refresh racing our own teardown can never resurrect a released
    /// lease — it simply no-ops if the release already landed.
    private func refreshRuntimeOptions() {
        guard owesRuntimeRelease, !isCleaningUp else { return }
        let leaseID = runtimeLeaseID
        let options = makeRuntimeOptions()
        Task { await MonitorRuntime.shared.updateOptions(leaseID: leaseID, options: options) }
    }

    // MARK: - Live configuration

    /// Apply a new board configuration in place (no view rebuild). Strips
    /// agent-gated placements, forwards to the board, mirrors click-through, and
    /// repoints the lease's on-demand sampling.
    func apply(configuration newConfiguration: MonitorBoardConfiguration) {
        let gated = Self.gatedConfiguration(newConfiguration, agentFleetEnabled: agentFleetEnabled)
        // No-op when nothing changed: a board edit made ON this live wallpaper
        // already reflects in the board, and its persist round-trips back here — so
        // re-applying the identical config would needlessly rebuild the hosting view.
        guard gated != configuration else { return }
        configuration = gated
        boardHost.apply(configuration: gated)
        // While editing, interaction stays forced on regardless of the persisted
        // flag; the value is restored when edit mode exits.
        let interactive = isEditing ? true : gated.mouseInteractionEnabled
        setMouseInteractionEnabled(interactive)
        (window as? VideoWallpaperWindow)?.setWallpaperMouseInteractionEnabled(interactive)
        refreshRuntimeOptions()
        restartPumpCadence()
    }

    // MARK: - Editing

    /// Enter/exit board edit mode (menu-bar "Edit Widgets" drives this). The
    /// board's own Done control also exits; both routes funnel through the board
    /// host's `onEditingChanged`, which forces/restores mouse interaction — so
    /// this only has to flip the board state.
    func setEditing(_ editing: Bool) {
        boardHost.setEditing(editing)
    }

    var isEditing: Bool { boardHost.isEditing }

    /// Force mouse interaction on while editing (the persisted wallpaper is
    /// usually click-through, which would leave the edit chrome unclickable), and
    /// restore the persisted state on exit. Drives BOTH the view's hitTest gate
    /// and the enclosing wallpaper window's `ignoresMouseEvents`/level policy.
    private func handleEditingChanged(_ editing: Bool) {
        let interactive = editing ? true : configuration.mouseInteractionEnabled
        setMouseInteractionEnabled(interactive)
        (window as? VideoWallpaperWindow)?.setWallpaperMouseInteractionEnabled(interactive)
    }

    // MARK: - Data pump

    private func startPump() {
        pumpTask?.cancel()
        guard !isSuspended, !isCleaningUp else { return }
        let interval = Self.pumpInterval(forHz: configuration.refreshHz)
        pumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, !self.isCleaningUp, !self.isSuspended else { return }
                self.pushLatestSnapshot(force: false)
            }
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    /// Restart the pump so a refresh-rate change takes effect immediately.
    private func restartPumpCadence() {
        guard !isSuspended, !isCleaningUp else { return }
        startPump()
    }

    /// Pushes the newest snapshot when it is newer than the last one drawn.
    /// `force` re-pushes the current newest even if the generation is unchanged
    /// (used right after init / resume so the board paints immediately).
    private func pushLatestSnapshot(force: Bool) {
        guard !isCleaningUp else { return }
        let broker = MonitorRuntime.shared.broker
        let after = force ? 0 : lastGeneration
        guard let update = broker.latest(after: after) else { return }
        lastGeneration = update.generation
        boardHost.push(update.snapshot)
    }

    private static func pumpInterval(forHz hz: Double) -> Duration {
        let clamped = MonitorBoardConfiguration.clampedRefreshHz(hz)
        let seconds = 1.0 / clamped
        return .milliseconds(Int((seconds * 1000).rounded()))
    }

    // MARK: - Performance profile (suspend / resume)

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        switch profile {
        case .quality:
            resume()
        case .suspended:
            suspend()
        }
    }

    private func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        // Stopping the pump halts native snapshot delivery; the board's own
        // CoreAnimation loops are stilled via reduce-motion inside the widgets,
        // and no vsync work is scheduled while no new snapshot arrives.
        stopPump()
    }

    private func resume() {
        guard isSuspended else { return }
        isSuspended = false
        // Reflect the current state the instant playback resumes, then restart
        // the cadence.
        pushLatestSnapshot(force: true)
        startPump()
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowMouseInteraction else { return nil }
        return super.hitTest(point)
    }

    /// Update click-through at runtime (e.g. entering edit mode forces
    /// interaction on the live wallpaper). Mirrors the window flag set alongside.
    func setMouseInteractionEnabled(_ enabled: Bool) {
        allowMouseInteraction = enabled
        boardHost.setMouseInteractionEnabled(enabled)
    }

    override func layout() {
        super.layout()
        boardHost.frame = bounds
    }

    // MARK: - Cleanup

    func cleanup() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        stopPump()
        // Flush any debounced board edit BEFORE detaching the callback, so a final
        // edit made just before the window closed isn't lost when the pending task
        // is cancelled.
        boardHost.flushPendingEdits()
        boardHost.onConfigurationEdited = nil
        if owesRuntimeRelease {
            owesRuntimeRelease = false
            let leaseID = runtimeLeaseID
            Task { await MonitorRuntime.shared.release(leaseID: leaseID) }
        }
    }

    // MARK: - Menu-bar top inset

    /// Normalized top-inset (menu-bar) forbidden zone for a board filling
    /// `frame`: the menu-bar height (top diff only — the Dock is a bottom inset
    /// and stays out) over the screen height, from the `NSScreen` whose frame
    /// matches. 0 when no screen matches (e.g. mid display-reconfigure) — the
    /// board simply has no top forbidden zone until the next reconcile. Shared
    /// by the overlay controller so both hosts derive the fraction identically.
    static func menuBarTopInsetFraction(forFrame frame: NSRect) -> CGFloat {
        guard let screen = NSScreen.screens.first(where: { framesMatch($0.frame, frame) }) else { return 0 }
        let height = screen.frame.height
        guard height > 0 else { return 0 }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return max(0, min(menuBar / height, 1))
    }

    private static func framesMatch(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 1 && abs(a.origin.y - b.origin.y) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    // MARK: - Agent gate

    /// Strip AI-agent placements (fleet / usage) when the Pro `.agentFleet`
    /// capability is not unlocked, so a Lite user (or a persisted Pro config
    /// opened under Lite) can never surface locked widgets. A no-op when the
    /// gate is open.
    static func gatedConfiguration(
        _ configuration: MonitorBoardConfiguration,
        agentFleetEnabled: Bool
    ) -> MonitorBoardConfiguration {
        guard !agentFleetEnabled else { return configuration }
        let kept = configuration.widgets.filter { !$0.kind.requiresAgentFleet }
        guard kept.count != configuration.widgets.count else { return configuration }
        var gated = configuration
        gated.widgets = kept
        return gated
    }
}
