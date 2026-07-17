#if !LITE_BUILD
import LiveWallpaperSharedUI
import SwiftUI

struct StorageOverviewSegment: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let color: Color
    let bytes: UInt64
    let valueText: String
}

struct StorageOverviewPanel: View {
    let totalText: String
    let isLoading: Bool
    let segments: [StorageOverviewSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Label("Storage Footprint", systemImage: "chart.bar.xaxis")
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .foregroundStyle(.primary)

                Spacer(minLength: DesignTokens.Spacing.md)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Calculating storage footprint…"))
                } else {
                    Text(verbatim: totalText)
                        .font(DesignTokens.Typography.pageTitle)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            StorageSegmentedBar(segments: segments)

            if segments.isEmpty {
                Text("No downloaded content or cache files yet.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 118), spacing: DesignTokens.Spacing.md)],
                    alignment: .leading,
                    spacing: DesignTokens.Spacing.xs
                ) {
                    ForEach(segments) { segment in
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Circle()
                                .fill(segment.color)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)

                            Text(segment.title)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(.secondary)

                            Text(verbatim: segment.valueText)
                                .font(DesignTokens.Typography.metric)
                                .foregroundStyle(.primary)
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: 0.5)
        )
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}

private struct StorageSegmentedBar: View {
    let segments: [StorageOverviewSegment]

    private var totalBytes: UInt64 {
        segments.reduce(UInt64(0)) { $0 + $1.bytes }
    }

    var body: some View {
        GeometryReader { proxy in
            let nonZeroSegments = segments.filter { $0.bytes > 0 }
            let spacing: CGFloat = 2
            let usableWidth = max(0, proxy.size.width - spacing * CGFloat(max(nonZeroSegments.count - 1, 0)))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))

                if totalBytes > 0 {
                    HStack(spacing: spacing) {
                        ForEach(nonZeroSegments) { segment in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(segment.color)
                                .frame(width: max(3, usableWidth * CGFloat(Double(segment.bytes) / Double(totalBytes))))
                        }
                    }
                }
            }
        }
        .frame(height: 9)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Compact metric card for the Storage dashboard.
struct StorageDashboardTile<Value: View, Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let accent: Color
    let subtitle: Text
    @ViewBuilder var value: () -> Value
    @ViewBuilder var actions: () -> Actions

    init(
        title: LocalizedStringKey,
        systemImage: String,
        accent: Color,
        subtitle: Text,
        @ViewBuilder value: @escaping () -> Value,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.subtitle = subtitle
        self.value = value
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                        .fill(accent.opacity(0.16))
                        .frame(width: 30, height: 30)
                    Image(systemName: systemImage)
                        .font(.body.weight(.medium))
                        .foregroundStyle(accent)
                }
                .accessibilityHidden(true)

                Spacer(minLength: DesignTokens.Spacing.sm)

                HStack(spacing: DesignTokens.Spacing.xs) {
                    actions()
                }
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                value()
                    .frame(minHeight: 30, alignment: .leading)

                Text(title)
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                subtitle
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: 0.5)
        )
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}

/// Trailing ⓘ that reveals a section's detail in a popover, so the dashboard
/// stays uncluttered with extra explanation hidden by default.
struct StorageInfoButton<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(Text("Details"))
        .accessibilityLabel(Text("Details"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content().padding(14)
        }
    }
}

extension View {
    func storageDestructiveIconStyle() -> some View {
        buttonStyle(.borderless)
            .foregroundStyle(DesignTokens.Colors.Status.danger)
    }
}
#endif
