import LiveWallpaperSharedUI
import SwiftUI

/// Collapsed sidebar-footer entry point for the system dashboard. Shows a single
/// liquid-glass capsule with a live health dot; tapping reveals the full
/// `SystemMonitorView` gauges in a popover. Holding a monitoring reference while
/// visible keeps the dot live, while avoiding the always-on render of four
/// animated rings and keeping the sidebar footer height fixed.
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
        header
            .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                SystemMonitorView(
                    activeDisplayCount: activeDisplayCount,
                    totalDisplayCount: totalDisplayCount
                )
                .padding(DesignTokens.Spacing.sm)
                .frame(width: 244)
            }
            .onAppear { monitor.startMonitoring() }
            .onDisappear { monitor.stopMonitoring() }
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
        .adaptiveGlassSurface(.capsule, interactive: true)
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
