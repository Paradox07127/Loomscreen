import SwiftUI
import LiveWallpaperCore

// MARK: - Widget factory
//
// Maps a `MonitorWidgetKind` to its real instrument view, given the
// orchestrator-owned `MonitorWidgetContext` (snapshot + history + placement +
// flags). Every kind routes to a concrete widget view under `Monitor/Widgets/`.

enum MonitorWidgetFactory {

    /// Localized display name for a kind — the label a human reads in the widget
    /// catalog and the inspector's instrument list. Acronyms (CPU/GPU) resolve to
    /// the same word in every language; the rest translate. Rendered at the call
    /// site with `Text(verbatim:)` because the localization already happened here.
    static func displayName(_ kind: MonitorWidgetKind) -> String {
        switch kind {
        case .cpu: return String(localized: "CPU", comment: "Monitor widget name: CPU instrument.")
        case .memory: return String(localized: "Memory", comment: "Monitor widget name: Memory instrument.")
        case .gpu: return String(localized: "GPU", comment: "Monitor widget name: GPU instrument.")
        case .network: return String(localized: "Network", comment: "Monitor widget name: Network instrument.")
        case .disk: return String(localized: "Disk", comment: "Monitor widget name: Disk I/O instrument.")
        case .power: return String(localized: "Power", comment: "Monitor widget name: Power/battery instrument.")
        case .clock: return String(localized: "Clock", comment: "Monitor widget name: Clock instrument.")
        case .processes: return String(localized: "Processes", comment: "Monitor widget name: top-processes instrument.")
        case .health: return String(localized: "Health", comment: "Monitor widget name: source-health instrument.")
        case .usage: return String(localized: "Usage", comment: "Monitor widget name: account-usage instrument.")
        case .fleet: return String(localized: "Fleet", comment: "Monitor widget name: AI agent fleet instrument.")
        case .aiEngine: return String(localized: "AI Engine", comment: "Monitor widget name: Apple Neural Engine instrument.")
        }
    }

    /// SF Symbol for a kind — the glyph shown in the inspector instrument list and
    /// the board's name-only preview tiles.
    static func icon(_ kind: MonitorWidgetKind) -> String {
        switch kind {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "cpu.fill"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .power: return "bolt.fill"
        case .clock: return "clock"
        case .processes: return "list.bullet"
        case .health: return "checklist"
        case .usage: return "gauge.with.needle"
        case .fleet: return "point.3.filled.connected.trianglepath.dotted"
        case .aiEngine: return "brain"
        }
    }

    /// The tile body for a placement. `cornerRadius` is threaded through by the
    /// caller for layout geometry but isn't consumed here directly.
    @MainActor @ViewBuilder
    static func tile(context: MonitorWidgetContext, cornerRadius: CGFloat) -> some View {
        switch context.placement.kind {
        case .cpu:
            MonitorCPUWidgetView(context: context)
        case .memory:
            MonitorMemoryWidgetView(context: context)
        case .gpu:
            MonitorGPUWidgetView(context: context)
        case .network:
            MonitorNetworkWidgetView(context: context)
        case .disk:
            MonitorDiskWidgetView(context: context)
        case .power:
            MonitorPowerWidgetView(context: context)
        case .clock:
            MonitorClockWidgetView(context: context)
        case .processes:
            MonitorProcessesWidgetView(context: context)
        case .health:
            MonitorHealthWidgetView(context: context)
        case .usage:
            MonitorUsageWidgetView(context: context)
        case .fleet:
            MonitorFleetWidgetView(context: context)
        case .aiEngine:
            MonitorAIEngineWidgetView(context: context)
        }
    }
}

/// A layout-only placeholder tile: the widget's icon + localized name centered in
/// the standard panel chrome. The inspector preview renders these instead of the
/// live instruments — arranging the board is about placement, not live data, so no
/// snapshot flows through the preview. The wallpaper itself always renders the
/// real instruments (`MonitorWidgetFactory.tile`).
struct MonitorWidgetNameTile: View {
    let kind: MonitorWidgetKind
    let cellHeight: CGFloat
    /// Board-authoritative radius (`MonitorBoardGeometry.cornerRadius`) so the
    /// fill stays concentric with the selection border on any board size.
    var cornerRadius: CGFloat = MonitorDesign.cornerRadiusDefault

    private var scale: MonitorDesign.TypeScale { .init(cellHeight: cellHeight) }

    var body: some View {
        VStack(spacing: max(4, cellHeight * 0.05)) {
            Image(systemName: MonitorWidgetFactory.icon(kind))
                .font(.system(size: scale.hero * 0.58, weight: .regular))
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: MonitorWidgetFactory.displayName(kind))
                .font(MonitorDesign.subFont(size: scale.caption + 1))
                .foregroundStyle(MonitorDesign.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MonitorDesign.contentInsetH)
        .monitorPanelChrome(cornerRadius: cornerRadius)
    }
}
