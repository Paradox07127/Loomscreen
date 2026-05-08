import SwiftUI

/// System monitor popover anchored on the footer monitor dot. Mirrors the
/// previous mini-dashboard exactly so users who relied on the chips still
/// see CPU / GPU / RAM / FPS at a glance — just no longer permanently
/// occupying the popover's top row.
struct MenuBarDiagnosticsPopover: View {
    @AppStorage(MenuBarPreferenceKey.ramScope) private var ramScopeRaw: String = "system"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var monitor: SystemMonitor { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "speedometer")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text("System Monitor")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 0) {
                ramScopeButton(label: "All", value: "system")
                ramScopeButton(label: "App", value: "app")
            }
            .padding(2)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 180)

            chipRow
        }
        .padding(12)
        .frame(width: 260)
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            DashboardChip(label: "CPU", value: cpuPercent, color: monitorColor(for: cpuPercent), icon: "cpu")
            DashboardChip(label: "GPU", value: monitor.gpuUsage, color: monitorColor(for: monitor.gpuUsage), icon: "square.stack.3d.up.fill")
            DashboardChip(label: "RAM", value: ramPercent, color: monitorColor(for: ramPercent), icon: "memorychip")
            DashboardChip(
                label: monitor.videoFPS > 0 ? "EST" : "—",
                value: min(monitor.videoFPS, 120) / 120 * 100,
                color: monitor.videoFPS >= 30 ? .green : (monitor.videoFPS > 0 ? .orange : .secondary),
                icon: "speedometer",
                displayValue: monitor.videoFPS > 0 ? "\(Int(monitor.videoFPS))" : "—"
            )
        }
    }

    @ViewBuilder
    private func ramScopeButton(label: String, value: String) -> some View {
        Button {
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) {
                ramScopeRaw = value
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: ramScopeRaw == value ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            ramScopeRaw == value
                ? .regular.tint(Color.accentColor.opacity(0.35)).interactive()
                : .clear.interactive(),
            in: .capsule
        )
        .accessibilityLabel(value == "system" ? "Show whole-system memory usage" : "Show this app's memory usage")
    }

    private var ramPercent: Double {
        ramScopeRaw == "app" ? monitor.memoryPercentage() : monitor.systemMemoryUsage * 100
    }

    private var cpuPercent: Double {
        ramScopeRaw == "app" ? monitor.cpuUsage : monitor.systemCpuUsage
    }

    private func monitorColor(for percent: Double) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return .green
    }
}

/// Single CPU/GPU/RAM/FPS chip used by the diagnostics popover.
struct DashboardChip: View {
    let label: String
    let value: Double
    let color: Color
    let icon: String
    var displayValue: String?

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text(displayValue ?? "\(Int(value))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Capsule()
                .fill(Color.gray.opacity(0.18))
                .frame(height: 3)
                .overlay(
                    GeometryReader { geo in
                        Capsule()
                            .fill(color)
                            .frame(width: geo.size.width * CGFloat(min(max(value, 0), 100) / 100))
                    }
                )
                .frame(height: 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignTokens.Corner.sm))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(displayValue ?? "\(Int(value))%")")
    }
}
