import SwiftUI

/// The standard widget shell every Monitor widget wraps itself in, so spacing and
/// typography stay uniform across the board. Composes the instrument-panel chrome,
/// the HIG content insets, and the mock's `.chd` header idiom — a whisper label
/// (with optional leading SF Symbol) on the left, a micro-status readout on the
/// right — above a content slot.
///
/// The type scale is cell-derived (pass the widget's rendered height so the
/// label/caption sizes track SPEC §3.0); the corner radius is NOT — the panel
/// chrome fills the tile's full bounds with zero inset, so it must share the
/// one board-wide radius (`MonitorBoardGeometry.cornerRadius`) every tile is
/// clipped/stroked with, or the fill reads as mis-centred inside its own tile.
/// The default matches the board's fixed Apple desktop-widget radius, which is
/// what the live wallpaper (point-scale 1) always renders at; the scaled
/// inspector preview draws name tiles that receive the geometry radius directly.
/// Content is caller-provided, so any embedded text should use `Text(verbatim:)`.
struct MonitorWidgetContainer<Content: View, Status: View>: View {
    var label: String
    /// Optional SF Symbol name shown before the label.
    var systemImage: String?
    /// Cell height in points; drives the type scale only (see corner-radius note above).
    var cellHeight: CGFloat
    /// Panel corner radius — zero-inset, so this should equal the outer tile's
    /// radius exactly (see type doc). Defaults to the board's Apple desktop-widget
    /// radius: the live wallpaper always renders at point-scale 1, so the static
    /// default matches `MonitorBoardGeometry.cornerRadius` wherever real
    /// instruments draw (the scaled inspector preview renders name tiles, which
    /// receive the geometry radius explicitly).
    var cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius
    @ViewBuilder var status: () -> Status
    @ViewBuilder var content: () -> Content

    init(
        label: String,
        systemImage: String? = nil,
        cellHeight: CGFloat = 150,
        cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius,
        @ViewBuilder status: @escaping () -> Status = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.systemImage = systemImage
        self.cellHeight = cellHeight
        self.cornerRadius = cornerRadius
        self.status = status
        self.content = content
    }

    private var scale: MonitorDesign.TypeScale { .init(cellHeight: cellHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.label * 0.5) {
            header
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, MonitorDesign.contentInsetH)
        .padding(.vertical, MonitorDesign.contentInsetV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .monitorPanelChrome(cornerRadius: cornerRadius)
    }

    private var header: some View {
        // Title reads one size up from the whisper labels so the instrument's
        // name anchors the card at the fixed Apple frames.
        let titleSize = scale.label + 1
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(MonitorDesign.inkFaint)
            }
            Text(verbatim: label.uppercased())
                .font(MonitorDesign.labelFont(size: titleSize))
                .tracking(MonitorDesign.labelTracking(size: titleSize))
                .foregroundStyle(MonitorDesign.inkFaint)
            Spacer(minLength: 4)
            status()
                .font(MonitorDesign.labelFont(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
        }
    }
}

#Preview("Widget container") {
    HStack(spacing: 24) {
        // 2×2 square footprint
        MonitorWidgetContainer(label: "CPU", systemImage: "cpu", cellHeight: 150) {
            HStack(spacing: 5) {
                BreathingDot(color: MonitorDesign.signalAmber, size: 6)
                Text(verbatim: "42%").foregroundStyle(MonitorDesign.inkMuted)
            }
        } content: {
            ArcGauge(value: 0.42, peak: 0.61) {
                Text(verbatim: "42")
                    .font(MonitorDesign.heroFont(size: 28)).monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkPrimary)
            }
        }
        .frame(width: 150, height: 150)

        // 4×2 wide footprint
        MonitorWidgetContainer(label: "NETWORK", systemImage: "wifi", cellHeight: 150) {
            Text(verbatim: "6.2 MB/s").foregroundStyle(MonitorDesign.inkMuted)
        } content: {
            MirroredAreaChart(
                up: [3, 4, 5.5, 6.8, 5.2, 4.1, 6.3, 8.1, 7.2, 5.4],
                down: [0.4, 0.6, 0.9, 0.7, 0.5, 0.8, 1.1, 0.9, 0.6, 0.5]
            )
        }
        .frame(width: 320, height: 150)
    }
    .padding(32)
    .background(MonitorDesign.boardWash)
}
