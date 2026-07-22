import SwiftUI

struct MonitorWidgetContainer<Content: View, Status: View>: View {
    var label: String
    /// Optional SF Symbol name shown before the label.
    var systemImage: String?
    /// Cell height in points; drives the type scale only (see corner-radius note above).
    var cellHeight: CGFloat
    /// Panel corner radius — zero-inset, so this should equal the outer tile's radius exactly (see type doc).
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
