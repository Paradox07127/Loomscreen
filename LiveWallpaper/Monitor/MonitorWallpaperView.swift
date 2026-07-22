import AppKit
import LiveWallpaperCore
import os

/// Desktop wallpaper host for the native Monitor widget board.
@MainActor
final class MonitorWallpaperView: NSView, WallpaperPerformanceConfigurable, WallpaperResourceCleanable {

    private static let log = os.Logger(subsystem: "com.livewallpaper", category: "MonitorWallpaper")

    private let boardHost: MonitorBoardHostView
    private var configuration: MonitorBoardConfiguration

    /// Mirrors `configuration.mouseInteractionEnabled`; when false the wallpaper stays click-through.
    private var allowMouseInteraction: Bool

    /// Fires (debounced by the board host) whenever the user commits a board
    /// edit; the session builder points this at `ScreenManager`.
    var onConfigurationEdited: ((MonitorBoardConfiguration) -> Void)?

    /// Data pump. `nil` while suspended / torn down.
    private var pumpTask: Task<Void, Never>?
    private var lastGeneration: UInt64 = 0
    private var isSuspended = false
    private var isCleaningUp = false
    /// The shared pipeline in production; injectable so the suspend/energy tests
    /// can watch a lease without racing the app-wide singleton.
    private let runtime: MonitorRuntime
    /// Sequences this view's lease commands before they enter the runtime actor.
    private let runtimeLeaseSlot: MonitorRuntimeLeaseSlot
    /// Generation-scoped authority consumed by cleanup/deinit exactly once.
    private var runtimeLease: MonitorRuntimeLeaseHandle?
    private var lastRuntimeTask: Task<Void, Never>?

    init(
        frame frameRect: NSRect,
        configuration: MonitorBoardConfiguration,
        runtime: MonitorRuntime = .shared
    ) {
        self.runtime = runtime
        self.runtimeLeaseSlot = runtime.makeLeaseSlot()
        self.configuration = configuration
        self.allowMouseInteraction = configuration.mouseInteractionEnabled
        self.boardHost = MonitorBoardHostView(
            frame: NSRect(origin: .zero, size: frameRect.size),
            configuration: configuration,
            topInsetFraction: Self.menuBarTopInsetFraction(forFrame: frameRect)
        )

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        boardHost.frame = bounds
        boardHost.autoresizingMask = [.width, .height]
        addSubview(boardHost)

        boardHost.resetHistory()

        // Route committed board edits back out; re-apply the agent gate before
        // persisting so a stripped board can never write fleet/usage back in.
        boardHost.onConfigurationEdited = { [weak self] edited in
            self?.acceptBoardConfigurationEdit(edited)
        }

        boardHost.onEditingChanged = { [weak self] editing in
            self?.handleEditingChanged(editing)
        }

        MonitorSourceRegistration.registerDefaultFactories()
        runtimeLease = runtimeLeaseSlot.acquire(options: makeRuntimeOptions())

        startPump()
        pushLatestSnapshot(force: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pumpTask?.cancel()
        runtimeLease?.release()
    }

    // MARK: - Runtime options

    /// Agent-only boards do not need the host metrics pipeline. Keep this
    /// exhaustive so a newly-added widget kind must declare its source demand.
    nonisolated static func requiresSystemMetrics(
        for kinds: Set<MonitorWidgetKind>
    ) -> Bool {
        kinds.contains { kind in
            switch kind {
            case .usage, .fleet:
                false
            case .cpu, .memory, .gpu, .network, .disk, .power, .processes, .aiEngine:
                true
            }
        }
    }

    private func makeRuntimeOptions() -> MonitorRuntimeOptions {
        let kinds = Set(configuration.widgets.map(\.kind))
        let wantsAgents = kinds.contains(.fleet)
        let wantsUsage = kinds.contains(.usage)
        let wantsProcesses = kinds.contains(.processes)
        // Roots stay nil here: the runtime resolves the security-scoped grants
        // itself so scope lifetime matches pipeline (not view) lifetime.
        return MonitorRuntimeOptions(
            system: Self.requiresSystemMetrics(for: kinds),
            agents: wantsAgents,
            usage: wantsUsage,
            topProcesses: wantsProcesses,
            activeWidgetKinds: kinds,
            gpuSampleSeconds: MonitorWidgetDraft.gpuSampleSeconds(in: configuration.widgets)
        )
    }

    /// Repoint the shared lease's on-demand sampling for a live config change.
    private func refreshRuntimeOptions() {
        guard let runtimeLease, !isCleaningUp else { return }
        runtimeLease.updateOptions(makeRuntimeOptions())
    }

    /// Production entry for edits committed by the live board.
    func acceptBoardConfigurationEdit(_ edited: MonitorBoardConfiguration) {
        guard !isCleaningUp else { return }
        configuration = edited
        refreshRuntimeOptions()
        restartPumpCadence()
        onConfigurationEdited?(edited)
    }

    func waitUntilRuntimeSettled() async {
        if let runtimeLease {
            await runtimeLease.waitUntilSettled()
        } else {
            await lastRuntimeTask?.value
        }
    }

    // MARK: - Live configuration

    /// Apply a new board configuration in place (no view rebuild).
    func apply(configuration newConfiguration: MonitorBoardConfiguration) {
        // Avoid rebuilding the host when a persisted board edit is already visible.
        guard newConfiguration != configuration else { return }
        configuration = newConfiguration
        boardHost.apply(configuration: newConfiguration)
        let interactive = isEditing ? true : newConfiguration.mouseInteractionEnabled
        setMouseInteractionEnabled(interactive)
        (window as? VideoWallpaperWindow)?.setWallpaperMouseInteractionEnabled(interactive)
        refreshRuntimeOptions()
        restartPumpCadence()
    }

    // MARK: - Editing

    /// Enter/exit board edit mode (menu-bar "Edit Widgets" drives this).
    func setEditing(_ editing: Bool) {
        boardHost.setEditing(editing)
    }

    var isEditing: Bool { boardHost.isEditing }

    /// Whether the suspend signal reached the board (its clock + dot animations).
    /// Mirrors `isEditing`'s pass-through; the energy regression test asserts on it.
    var isBoardSuspended: Bool { boardHost.isSuspended }

    /// Force mouse interaction on while editing (the persisted wallpaper is usually click-through, which would leave the edit chrome unclickable), and restore the persisted state on exit.
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
    private func pushLatestSnapshot(force: Bool) {
        guard !isCleaningUp else { return }
        let broker = runtime.broker
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

    /// Stop paying for a wallpaper nobody can see.
    private func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        stopPump()
        setRuntimePaused(true)
        boardHost.setSuspended(true)
    }

    private func resume() {
        guard isSuspended else { return }
        isSuspended = false
        setRuntimePaused(false)
        boardHost.setSuspended(false)
        // Reflect the current state the instant playback resumes, then restart the cadence.
        pushLatestSnapshot(force: true)
        startPump()
    }

    /// Pause (never release) the lease on suspend.
    private func setRuntimePaused(_ paused: Bool) {
        guard let runtimeLease, !isCleaningUp else { return }
        runtimeLease.setPaused(paused)
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
        // Flush any debounced board edit BEFORE detaching the callback, so a final edit made just before the window closed isn't lost when the pending task is cancelled.
        boardHost.flushPendingEdits()
        boardHost.onConfigurationEdited = nil
        let lease = runtimeLease
        runtimeLease = nil
        lastRuntimeTask = lease?.release()
    }

    // MARK: - Menu-bar top inset

    /// Returns the normalized menu-bar inset for the matching screen.
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
}
