import AppKit
import LiveWallpaperCore
import SwiftUI

struct MonitorBoardPreviewArea: View {
    let screen: Screen
    let screenManager: ScreenManager
    let featureCatalog: FeatureCatalog

    @State private var board: MonitorBoardConfiguration = .default

    private var agentFleetEnabled: Bool {
        featureCatalog.isEnabled(.agentFleet)
    }

    /// The display's aspect ratio.
    private var screenAspect: CGFloat {
        let f = screen.frame
        guard f.width > 0, f.height > 0 else { return 16.0 / 9.0 }
        return f.width / f.height
    }

    /// The real display's menu-bar forbidden zone as a fraction of its height (top diff only — Dock excluded).
    private var topInsetFraction: CGFloat {
        let f = screen.nsScreen.frame
        guard f.height > 0 else { return 0 }
        let menuBar = f.maxY - screen.nsScreen.visibleFrame.maxY
        return max(0, min(menuBar / f.height, 1))
    }

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fittedSize(in: geo.size, aspect: screenAspect)
            MonitorBoardPreview(
                configuration: board,
                agentFleetEnabled: agentFleetEnabled,
                topInsetFraction: topInsetFraction,
                referenceWidth: max(screen.frame.width, 1),
                onConfigurationEdited: { edited in
                    // A live board edit (drag/add/remove/resize) already reflects on the preview; mirror it into our state and persist WITHOUT a session restart (the wallpaper's own path).
                    board = edited
                    screenManager.persistMonitorConfigurationFromBoard(edited, for: screen)
                }
            )
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
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

    /// Load the persisted board for this screen.
    private func reload() {
        if case .monitor(let persisted)? = screenManager.getConfiguration(for: screen)?.activeWallpaper {
            if board != persisted { board = persisted }
        } else {
            board = .default
        }
    }
}

struct MonitorBoardPreview: NSViewRepresentable {
    let configuration: MonitorBoardConfiguration
    let agentFleetEnabled: Bool
    /// Menu-bar forbidden-zone fraction, WYSIWYG with the real display.
    let topInsetFraction: CGFloat
    /// Real display width in points — the preview board scales Apple-size
    /// widgets down by boardWidth/referenceWidth so placement is WYSIWYG.
    let referenceWidth: CGFloat
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
            topInsetFraction: topInsetFraction,
            referenceWidth: referenceWidth
        )
        host.onConfigurationEdited = onConfigurationEdited
        context.coordinator.attach(host)
        // Defer published state changes until after SwiftUI's view-update transaction.
        Task { @MainActor in
            host.setEditing(true)
            host.setMouseInteractionEnabled(true)
        }
        return host
    }

    func updateNSView(_ host: MonitorBoardHostView, context: Context) {
        host.onConfigurationEdited = onConfigurationEdited
        let gated = MonitorWallpaperView.gatedConfiguration(
            configuration, agentFleetEnabled: agentFleetEnabled
        )
        let needsApply = context.coordinator.lastAppliedConfiguration != gated
        if needsApply { context.coordinator.lastAppliedConfiguration = gated }
        let referenceWidth = referenceWidth
        let topInsetFraction = topInsetFraction
        Task { @MainActor in
            host.setReferenceWidth(referenceWidth)
            if needsApply {
                host.apply(configuration: gated, topInsetFraction: topInsetFraction)
            }
            host.setEditing(true)
            host.setMouseInteractionEnabled(true)
        }
    }

    static func dismantleNSView(_ host: MonitorBoardHostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Manages the preview host's edit lifecycle only — no runtime lease, no pump (the preview shows name-only tiles).
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
