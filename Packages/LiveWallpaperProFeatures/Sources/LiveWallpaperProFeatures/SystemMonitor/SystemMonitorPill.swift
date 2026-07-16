import LiveWallpaperSharedUI
import SwiftUI

/// Sidebar-footer entry point for the system dashboard. The collapsed row keeps
/// a live health dot; tapping expands the full gauges upward inside the sidebar
/// on a glass surface instead of escaping into a popover.
public struct SystemMonitorPill: View {
    private var monitor = SystemMonitor.shared
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let activeDisplayCount: Int
    private let totalDisplayCount: Int

    public init(activeDisplayCount: Int = 0, totalDisplayCount: Int = 0) {
        self.activeDisplayCount = activeDisplayCount
        self.totalDisplayCount = totalDisplayCount
    }

    public var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            expandedPanel
        } else {
            header
                .adaptiveGlassSurface(.capsule, interactive: true)
        }
    }

    private var expandedPanel: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            SystemMonitorView(
                activeDisplayCount: activeDisplayCount,
                totalDisplayCount: totalDisplayCount
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .transition(.move(edge: .bottom).combined(with: .opacity))

            header
        }
        .padding(DesignTokens.Spacing.xs)
        .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.md), interactive: true)
    }

    private var header: some View {
        Button {
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.28))) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "cpu")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                Text("System", comment: "Sidebar system-monitor pill title.")
                    .font(DesignTokens.Typography.captionEmphasized)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Spacer(minLength: DesignTokens.Spacing.sm)

                // Redundant once the gauges are visible, so it fades out on expand.
                if !isExpanded {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: dotColor.opacity(0.6), radius: 3)
                        .animation(DesignTokens.motion(reduceMotion, .easeInOut(duration: 0.3)), value: monitor.loadLevel)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }

                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("System", comment: "Sidebar system-monitor pill title."))
        .accessibilityValue(loadDescription)
        .accessibilityHint(isExpanded
            ? Text("Tap to collapse", comment: "A11y hint for an expanded collapsible section header.")
            : Text("Tap to expand", comment: "A11y hint for a collapsed section header."))
    }

    private var dotColor: Color {
        switch monitor.loadLevel {
        case .calm:     return DesignTokens.Colors.Gauge.low
        case .elevated: return DesignTokens.Colors.Gauge.medium
        case .high:     return DesignTokens.Colors.Gauge.high
        }
    }

    /// Reuses the already-localized thermal labels so the dot's spoken state
    /// adds no new catalog strings.
    private var loadDescription: Text {
        switch monitor.loadLevel {
        case .calm:     return Text("Normal", comment: "Thermal state label.")
        case .elevated: return Text("Elevated", comment: "Thermal state label.")
        case .high:     return Text("High", comment: "Thermal state label.")
        }
    }
}
