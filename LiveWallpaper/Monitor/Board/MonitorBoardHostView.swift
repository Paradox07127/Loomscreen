import AppKit
import LiveWallpaperCore
import SwiftUI
import os

/// Native host for the Monitor v2 widget board — the AppKit shell that embeds
/// the SwiftUI board and bridges it to the runtime. `MonitorWallpaperView`
/// wraps this host as the wallpaper's render layer (the v1 WKWebView dashboard
/// is retired).
///
/// Responsibilities:
///   • Own an `NSHostingView` of `MonitorBoardRootView`, layer-backed + transparent.
///   • Data pump: `push(_:)` feeds the observable data model (externally driven —
///     no self-polling; the runtime pushes at its cadence).
///   • Live config: `apply(configuration:)` re-lays the board without a rebuild.
///   • Editing: `setEditing(_:)` toggles edit mode (menu-bar / API drives it).
///   • Click-through: when `mouseInteractionEnabled` is false the host intercepts
///     nothing (`hitTest → nil`), mirroring `MonitorWallpaperView`.
///   • Persistence-ready callback: `onConfigurationEdited` fires (debounced) on
///     committing edits — drag-end, add, remove, resize — never per mouse-move.
@MainActor
final class MonitorBoardHostView: NSView {

    private static let log = os.Logger(subsystem: "com.livewallpaper", category: "MonitorBoard")

    private let dataModel: MonitorBoardDataModel
    private let interactionModel: MonitorBoardInteractionModel
    private let hostingView: NSHostingView<MonitorBoardRootContainer>

    /// Mirrors the config's click-through flag; when false the board never
    /// intercepts events (same semantics as v1's `allowMouseInteraction`).
    private var allowMouseInteraction: Bool

    /// Board-scoped reduce-motion (system setting + config override), re-derived
    /// on `apply` and re-published whenever the root view is rebuilt.
    private var reduceMotion: Bool

    /// True while the performance policy has the wallpaper suspended. Published
    /// into the board's environment so the widgets' self-driven animation loops
    /// and the board clock stop — nothing else does that for them: they run off
    /// CoreAnimation/TimelineView, not off the data pump.
    private(set) var isSuspended = false

    /// When true the board renders name-only placeholder tiles (icon + widget
    /// name) instead of the live instruments — the inspector preview sets this so
    /// arranging the board never pumps live data. The wallpaper host leaves it false.
    private let nameOnlyTiles: Bool

    /// Debounce for persistence-ready configs. Committing edits (drag-end, add,
    /// remove, resize) already fire discretely, but rapid resize/remove bursts
    /// coalesce into one downstream write.
    private var pendingPersistTask: Task<Void, Never>?
    /// The config the debounced task is waiting to persist, retained alongside the
    /// task so a teardown can flush it synchronously (`flushPendingEdits`) instead
    /// of losing the user's final edit when the task is cancelled.
    private var pendingPersistConfig: MonitorBoardConfiguration?
    private static let persistDebounce: Duration = .milliseconds(250)

    /// Called with a persistence-ready configuration after a committing edit.
    /// Wave-3 integration wires this to the config store.
    var onConfigurationEdited: ((MonitorBoardConfiguration) -> Void)?

    /// Relays board edit-mode transitions (menu-driven, the board's own Done, or
    /// Esc) so the wallpaper host can force mouse interaction on while editing and
    /// restore the persisted click-through state on exit.
    var onEditingChanged: ((Bool) -> Void)? {
        get { interactionModel.onEditingChanged }
        set { interactionModel.onEditingChanged = newValue }
    }

    init(
        frame frameRect: NSRect,
        configuration: MonitorBoardConfiguration,
        agentFleetEnabled: Bool,
        nameOnlyTiles: Bool = false,
        topInsetFraction: CGFloat = 0,
        referenceWidth: CGFloat = 0
    ) {
        let reduceMotion = Self.effectiveReduceMotion(configuration)
        self.allowMouseInteraction = configuration.mouseInteractionEnabled
        self.nameOnlyTiles = nameOnlyTiles
        self.reduceMotion = reduceMotion
        self.dataModel = MonitorBoardDataModel()
        self.interactionModel = MonitorBoardInteractionModel(
            configuration: configuration,
            isAgentFleetEnabled: agentFleetEnabled
        )
        let container = MonitorBoardRootContainer(
            model: interactionModel,
            data: dataModel,
            reduceMotion: reduceMotion,
            suspended: false,
            nameOnlyTiles: nameOnlyTiles
        )
        self.hostingView = NSHostingView(rootView: container)

        super.init(frame: frameRect)

        interactionModel.topInsetFraction = topInsetFraction
        interactionModel.referenceWidth = referenceWidth

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        // Keep the hosting layer transparent so the desktop picture shows behind.
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)

        // Route committing edits out through the debounced persistence hook.
        interactionModel.onConfigurationEdited = { [weak self] config in
            self?.scheduleConfigPersist(config)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pendingPersistTask?.cancel()
    }

    // MARK: - Data pump (externally driven)

    /// Push the newest snapshot into the board. The runtime calls this at its
    /// own cadence; the host never polls. Rolling history is folded in here.
    func push(_ snapshot: MonitorSnapshot) {
        dataModel.update(snapshot)
    }

    /// Reset rolling history — call when the data pump restarts for a NEW
    /// session so stale series don't bleed across sessions (a suspend/resume of
    /// the same session should NOT reset). Wave-3 integration invokes this.
    func resetHistory() {
        dataModel.resetHistory()
    }

    // MARK: - Live configuration

    /// Apply a new configuration to the live board without rebuilding the view.
    /// Updates placements, click-through, and reduce-motion in place. A non-nil
    /// `topInsetFraction` repoints the menu-bar forbidden zone (e.g. the overlay
    /// moved to a display with a different menu-bar height) BEFORE the model
    /// reflows, so the reflow honours it; nil keeps the current fraction.
    func apply(configuration: MonitorBoardConfiguration, topInsetFraction: CGFloat? = nil) {
        // Drop any debounced persist still in flight: it carries an older board
        // edit that would otherwise fire after — and clobber — this newer
        // external configuration. (Unlike a teardown flush, here the pending edit
        // is genuinely superseded, so it is discarded rather than flushed.)
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        pendingPersistConfig = nil
        if let topInsetFraction { interactionModel.topInsetFraction = topInsetFraction }
        interactionModel.apply(configuration: configuration)
        allowMouseInteraction = configuration.mouseInteractionEnabled
        reduceMotion = Self.effectiveReduceMotion(configuration)
        rebuildRootView()
    }

    // MARK: - Suspend

    /// Stop/restart the board's self-driven work (the 1 Hz clock, the widgets'
    /// repeating dot animations) when the performance policy suspends the
    /// wallpaper. Independent of reduce-motion: that is the user's accessibility
    /// preference, this is "nobody can see this — stop spending".
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        rebuildRootView()
    }

    private func rebuildRootView() {
        hostingView.rootView = MonitorBoardRootContainer(
            model: interactionModel,
            data: dataModel,
            reduceMotion: reduceMotion,
            suspended: isSuspended,
            nameOnlyTiles: nameOnlyTiles
        )
    }

    /// Repoint the real-display width the board's point scale derives from
    /// (inspector preview after a screen switch). Reflows so Apple-size
    /// footprints re-fit at the new scale.
    func setReferenceWidth(_ width: CGFloat) {
        guard interactionModel.referenceWidth != width else { return }
        interactionModel.referenceWidth = width
        if interactionModel.boardSize != .zero {
            interactionModel.reflow(boardSize: interactionModel.boardSize)
        }
    }

    // MARK: - Editing

    /// Enter/exit edit mode (drag/add/remove/resize chrome). Driven by the
    /// menu bar / API later; exposed here as the single entry point.
    func setEditing(_ editing: Bool) {
        interactionModel.setEditing(editing)
    }

    var isEditing: Bool { interactionModel.isEditing }

    // MARK: - Click-through

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Fully passive when click-through: intercept nothing, exactly like v1.
        guard allowMouseInteraction else { return nil }
        return super.hitTest(point)
    }

    /// Update click-through at runtime (e.g. editing temporarily forces
    /// interaction on the live wallpaper). Mirrors the window flag set alongside.
    func setMouseInteractionEnabled(_ enabled: Bool) {
        allowMouseInteraction = enabled
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    // MARK: - Persistence debounce

    private func scheduleConfigPersist(_ config: MonitorBoardConfiguration) {
        pendingPersistTask?.cancel()
        pendingPersistConfig = config
        pendingPersistTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.persistDebounce)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingPersistConfig = nil
            self.pendingPersistTask = nil
            self.onConfigurationEdited?(config)
        }
    }

    /// Synchronously flush any debounced-but-not-yet-persisted edit, firing
    /// `onConfigurationEdited` immediately, then clear the pending state. Call this
    /// on EVERY teardown path (resource cleanup / window close / preview detach)
    /// BEFORE the host is released so the user's final edit is never dropped by the
    /// pending task being cancelled. Safe to call when nothing is pending (no-op).
    func flushPendingEdits() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        guard let config = pendingPersistConfig else { return }
        pendingPersistConfig = nil
        onConfigurationEdited?(config)
    }

    // MARK: - Helpers

    private static func effectiveReduceMotion(_ configuration: MonitorBoardConfiguration) -> Bool {
        if let override = configuration.reduceMotionOverride { return override }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// Wraps the board with the reduce-motion + suspend environment. A tiny container
/// so the host can swap the whole root view (config change, suspend) while
/// keeping the models — and with them the widgets' `@State`.
struct MonitorBoardRootContainer: View {
    @ObservedObject var model: MonitorBoardInteractionModel
    @ObservedObject var data: MonitorBoardDataModel
    let reduceMotion: Bool
    var suspended: Bool = false
    var nameOnlyTiles: Bool = false

    var body: some View {
        MonitorBoardRootView(model: model, data: data, nameOnlyTiles: nameOnlyTiles)
            .environment(\.monitorReduceMotion, reduceMotion)
            .environment(\.monitorSuspended, suspended)
    }
}

// MARK: - Reduce-motion environment

/// Board-scoped reduce-motion flag combining the system setting with the
/// config's `reduceMotionOverride`. Widget bodies read this to still their
/// animations. (`accessibilityReduceMotion` is read-only in SwiftUI, so we
/// carry our own writable key.)
private struct MonitorReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var monitorReduceMotion: Bool {
        get { self[MonitorReduceMotionKey.self] }
        set { self[MonitorReduceMotionKey.self] = newValue }
    }
}

// MARK: - Suspend environment

/// True while the performance policy has the wallpaper suspended (occluded,
/// full-screen game, battery saver). Deliberately NOT folded into
/// `monitorReduceMotion`: that one is the user's accessibility preference and is
/// the wrong lever for an energy decision — conflating them is what made v2's
/// `suspend()` a no-op. Read by anything that drives itself (the board clock, the
/// breathing dot) rather than by the data pump.
private struct MonitorSuspendedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var monitorSuspended: Bool {
        get { self[MonitorSuspendedKey.self] }
        set { self[MonitorSuspendedKey.self] = newValue }
    }
}
