import AppKit
import LiveWallpaperCore
import SwiftUI

/// SwiftUI wrapper that hosts the live Monitor board in the screen-detail
/// preview area (SPEC §4: preview = editor). Owns the board config it feeds the
/// representable: seeded from the persisted config and refreshed when a config
/// change lands (e.g. inspector-side edits to refresh rate / instruments), so
/// the preview and the side inspector stay in lock-step. Board edits made ON the
/// preview persist through the non-restarting board path and don't rebuild it.
struct MonitorBoardPreviewArea: View {
    let screen: Screen
    let screenManager: ScreenManager
    let featureCatalog: FeatureCatalog

    @State private var board: MonitorBoardConfiguration = .default

    private var agentFleetEnabled: Bool {
        featureCatalog.isEnabled(.agentFleet)
    }

    /// The display's aspect ratio. The preview board is laid out at the SAME
    /// proportions as the real screen so a widget's placement and size in the
    /// editor match where it lands on the wallpaper (normalized coords are relative
    /// to the board, so an off-aspect preview would skew both).
    private var screenAspect: CGFloat {
        let f = screen.frame
        guard f.width > 0, f.height > 0 else { return 16.0 / 9.0 }
        return f.width / f.height
    }

    /// The real display's menu-bar forbidden zone as a fraction of its height
    /// (top diff only — Dock excluded). Normalized, so it scales 1:1 onto the
    /// smaller preview board and the top no-go zone stays WYSIWYG. `Screen`
    /// always carries an `NSScreen`, so the real `visibleFrame` is used (no
    /// estimate needed).
    private var topInsetFraction: CGFloat {
        let f = screen.nsScreen.frame
        guard f.height > 0 else { return 0 }
        let menuBar = f.maxY - screen.nsScreen.visibleFrame.maxY
        return max(0, min(menuBar / f.height, 1))
    }

    var body: some View {
        // `.aspectRatio(_:contentMode:)` does not reliably letterbox an
        // NSViewRepresentable child (MonitorBoardPreview → MonitorBoardHostView):
        // absent a `sizeThatFits(_:nsView:context:)` override, the representable
        // can settle back to its `makeNSView` construction frame (480×168 ≈
        // 2.86:1 — the "~3:1 superwide" bug) instead of the aspectRatio-fitted
        // box. Compute the fitted box explicitly from GeometryReader's concrete
        // available space and pin it with `.frame(width:height:)`, which the
        // representable cannot reinterpret.
        GeometryReader { geo in
            let fitted = Self.fittedSize(in: geo.size, aspect: screenAspect)
            MonitorBoardPreview(
                configuration: board,
                agentFleetEnabled: agentFleetEnabled,
                topInsetFraction: topInsetFraction,
                onConfigurationEdited: { edited in
                    // A live board edit (drag/add/remove/resize) already reflects on
                    // the preview; mirror it into our state and persist WITHOUT a
                    // session restart (the wallpaper's own path).
                    board = edited
                    screenManager.persistMonitorConfigurationFromBoard(edited, for: screen)
                }
            )
            // Match the real display's proportions — the board area is the screen,
            // to scale, so editing is WYSIWYG.
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            // Letterbox: center the fitted box within the full available area.
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reload)
        .onChange(of: screen.id) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            guard let changedID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
                  changedID == screen.id else { return }
            reload()
        }
    }

    /// The largest box with `aspect` (width/height) that fits within
    /// `available`, i.e. `contentMode: .fit` computed by hand.
    private static func fittedSize(in available: CGSize, aspect: CGFloat) -> CGSize {
        guard available.width > 0, available.height > 0, aspect > 0 else { return .zero }
        if available.width / available.height > aspect {
            let height = available.height
            return CGSize(width: height * aspect, height: height)
        } else {
            let width = available.width
            return CGSize(width: width, height: width / aspect)
        }
    }

    /// Load the persisted board for this screen. When the board the store holds
    /// already matches ours (e.g. the notification we get right after persisting
    /// our own preview edit), this is a no-op assignment — no rebuild bounce.
    private func reload() {
        if case .monitor(let persisted)? = screenManager.getConfiguration(for: screen)?.activeWallpaper {
            if board != persisted { board = persisted }
        } else {
            board = .default
        }
    }
}

/// The Monitor board's layout editor, embedded in the screen-detail preview area
/// (SPEC §4: the preview IS the editor — same board engine, same edit gestures).
/// It wraps the wallpaper's own `MonitorBoardHostView` in edit mode with
/// `nameOnlyTiles` on, so each tile shows its icon + name rather than live data:
/// arranging the board is about placement, so the preview holds no runtime lease
/// and pumps no snapshots. The live wallpaper renders the real instruments.
///
/// Drag / add / remove / resize happen INSIDE this view and persist via
/// `onConfigurationEdited` (host-side debounced) WITHOUT a session restart. The
/// preview renders name-only tiles, so it holds NO runtime lease and pumps NO
/// snapshots — arranging the board is about placement, not live data.
struct MonitorBoardPreview: NSViewRepresentable {
    let configuration: MonitorBoardConfiguration
    let agentFleetEnabled: Bool
    /// Menu-bar forbidden-zone fraction, WYSIWYG with the real display.
    let topInsetFraction: CGFloat
    let onConfigurationEdited: (MonitorBoardConfiguration) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MonitorBoardHostView {
        let gated = MonitorWallpaperView.gatedConfiguration(
            configuration, agentFleetEnabled: agentFleetEnabled
        )
        let host = MonitorBoardHostView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 168),
            configuration: gated,
            agentFleetEnabled: agentFleetEnabled,
            nameOnlyTiles: true,
            topInsetFraction: topInsetFraction
        )
        host.onConfigurationEdited = onConfigurationEdited
        // Preview is always editable — this IS the editor (SPEC §4).
        host.setEditing(true)
        // Edit mode needs clicks even though the live wallpaper is click-through.
        host.setMouseInteractionEnabled(true)
        context.coordinator.attach(host)
        return host
    }

    func updateNSView(_ host: MonitorBoardHostView, context: Context) {
        // Keep the callback fresh (captures the current draft/handlers).
        host.onConfigurationEdited = onConfigurationEdited
        let gated = MonitorWallpaperView.gatedConfiguration(
            configuration, agentFleetEnabled: agentFleetEnabled
        )
        // Only re-apply when the config the preview holds actually differs, so a
        // board-originated edit we just mirrored back doesn't bounce a rebuild.
        if context.coordinator.lastAppliedConfiguration != gated {
            host.apply(configuration: gated, topInsetFraction: topInsetFraction)
            context.coordinator.lastAppliedConfiguration = gated
        }
        host.setEditing(true)
        host.setMouseInteractionEnabled(true)
    }

    static func dismantleNSView(_ host: MonitorBoardHostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Manages the preview host's edit lifecycle only — no runtime lease, no pump
    /// (the preview shows name-only tiles). Tracks the last-applied config so an
    /// edit mirrored back from the board doesn't bounce a rebuild.
    @MainActor
    final class Coordinator {
        private weak var host: MonitorBoardHostView?
        var lastAppliedConfiguration: MonitorBoardConfiguration?

        func attach(_ host: MonitorBoardHostView) {
            self.host = host
            self.lastAppliedConfiguration = nil
        }

        func detach() {
            // Flush any debounced board edit before dropping the callback so a final
            // preview edit isn't lost when the host is torn down.
            host?.flushPendingEdits()
            host?.onConfigurationEdited = nil
            host = nil
        }
    }
}
