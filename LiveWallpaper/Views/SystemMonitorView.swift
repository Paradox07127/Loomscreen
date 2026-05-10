import SwiftUI

struct SystemMonitorView: View {
    private var monitor = SystemMonitor.shared
    @State private var powerSource: PowerMonitor.PowerSource = PowerMonitor.shared.currentPowerSource
    @AppStorage("Dashboard.RAMScope") private var ramScopeRaw: String = "system"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ramPercent: Double {
        ramScopeRaw == "app" ? monitor.memoryPercentage() : monitor.systemMemoryUsage * 100
    }
    private var cpuPercent: Double {
        ramScopeRaw == "app" ? monitor.cpuUsage : monitor.systemCpuUsage
    }
    private var ramTitle: String { "RAM" }

    @ViewBuilder
    private func ramScopeButton(label: LocalizedStringKey, value: String) -> some View {
        Button {
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) { ramScopeRaw = value }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: ramScopeRaw == value ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(ramScopeRaw == value ? Color.accentColor.opacity(0.35) : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == "system"
            ? Text("Show whole-system memory usage", comment: "RAM scope toggle a11y label when scope is the whole system.")
            : Text("Show this app's memory usage", comment: "RAM scope toggle a11y label when scope is the LiveWallpaper app only."))
    }

    private var ramDetailText: Text {
        if ramScopeRaw == "app" {
            return Text("App: \(monitor.formattedMemoryUsage()) / \(monitor.formattedTotalMemory())", comment: "Dashboard memory detail. Placeholders are used and total memory.")
        }
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let usedBytes = UInt64(Double(totalBytes) * monitor.systemMemoryUsage)
        return Text("Sys: \(FormatUtils.formatBytes(usedBytes)) / \(monitor.formattedTotalMemory())", comment: "Dashboard system memory detail. Placeholders are used and total memory.")
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ramScopeButton(label: "All", value: "system")
                ramScopeButton(label: "App", value: "app")
            }
            .padding(2)
            .background(Capsule().fill(Color.gray.opacity(0.18)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("RAM scope"))

            gaugeGrid
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)

            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if monitor.videoFPS > 0 {
                            Text("Est \(Int(monitor.videoFPS)) FPS")
                                .font(.caption)
                                .fontWeight(.medium)
                        } else {
                            Text("Paused")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 4) {
                        Image(systemName: "thermometer.medium")
                            .font(.caption2)
                            .foregroundStyle(thermalColor)
                        Text(verbatim: monitor.thermalStateDescription)
                            .font(.caption)
                            .foregroundStyle(thermalColor)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ramDetailText
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 2)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: 220, alignment: .leading)
        .clipped()
        .onAppear {
            monitor.startMonitoring()
            powerSource = PowerMonitor.shared.currentPowerSource
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: PowerMonitor.powerSourceDidChangeNotification)) { notification in
            if let newSource = notification.userInfo?["newSource"] as? PowerMonitor.PowerSource {
                powerSource = newSource
            }
        }
    }

    private func colorForPercent(_ pct: Double) -> Color {
        if pct >= 80 { return .red }
        if pct >= 50 { return .orange }
        return .green
    }

    private var thermalColor: Color {
        switch monitor.thermalState {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    private var gaugeGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                MiniGaugeCard(title: "CPU", value: cpuPercent, color: colorForPercent(cpuPercent), icon: "cpu")
                    .accessibilityLabel(Text("CPU usage"))
                    .accessibilityValue(Text(verbatim: FormatUtils.formatPercent(cpuPercent)))

                MiniGaugeCard(title: "GPU", value: monitor.gpuUsage, color: colorForPercent(monitor.gpuUsage), icon: "square.stack.3d.up.fill")
                    .accessibilityLabel(Text("GPU usage"))
                    .accessibilityValue(Text(verbatim: FormatUtils.formatPercent(monitor.gpuUsage)))
            }

            HStack(spacing: 8) {
                MiniGaugeCard(title: ramTitle, value: ramPercent, color: colorForPercent(ramPercent), icon: "memorychip")
                    .accessibilityLabel(Text("\(ramTitle) usage"))
                    .accessibilityValue(Text(verbatim: FormatUtils.formatPercent(ramPercent)))

                PowerStatusCard(powerSource: powerSource)
                    .accessibilityLabel(Text("Power source"))
                    .accessibilityValue(powerSource.accessibilitySummary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - MiniGaugeCard

/// Compact 270° ring gauge for the dashboard grid.
struct MiniGaugeCard: View {
    let title: String
    let value: Double
    let color: Color
    let icon: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.75)
                .stroke(Color.gray.opacity(0.15), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(135))

            Circle()
                .trim(from: 0.0, to: CGFloat(displayedPercent) / 100 * 0.75)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.5, dampingFraction: 0.8)), value: displayedPercent)

            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)

            VStack(spacing: 0) {
                Text(verbatim: title)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(verbatim: FormatUtils.formatPercent(Double(displayedPercent)))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
            .offset(y: 18)
        }
        .frame(width: 54, height: 54)
        .frame(maxWidth: .infinity)
    }

    private var displayedPercent: Int {
        Int(min(max(value, 0), 100).rounded())
    }
}

// MARK: - PowerStatusCard

struct PowerStatusCard: View {
    let powerSource: PowerMonitor.PowerSource

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.75)
                .stroke(Color.gray.opacity(0.15), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(135))

            switch powerSource {
            case .battery(let level):
                Circle()
                    .trim(from: 0.0, to: CGFloat(level) * 0.75)
                    .stroke(statusColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(135))
            case .external:
                Circle()
                    .trim(from: 0.0, to: 0.75)
                    .stroke(statusColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(135))
            }

            Image(systemName: iconName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(statusColor)

            VStack(spacing: 0) {
                Text(verbatim: powerSource.shortLabel)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(verbatim: powerSource.valueLabel)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
            .offset(y: 18)
        }
        .frame(width: 54, height: 54)
        .frame(maxWidth: .infinity)
    }

    private var iconName: String {
        switch powerSource {
        case .battery(let level):
            if level <= 0.1 { return "battery.0" }
            if level <= 0.25 { return "battery.25" }
            if level <= 0.5 { return "battery.50" }
            if level <= 0.75 { return "battery.75" }
            return "battery.100"
        case .external:
            return "bolt.fill"
        }
    }

    private var statusColor: Color {
        switch powerSource {
        case .battery(let level):
            if level <= 0.2 { return .red }
            if level <= 0.5 { return .orange }
            return .green
        case .external:
            return .green
        }
    }
}

private extension PowerMonitor.PowerSource {
    var shortLabel: String {
        switch self {
        case .battery: return "BATT"
        case .external: return "PWR"
        }
    }

    var valueLabel: String {
        switch self {
        case .battery(let level): return FormatUtils.formatFractionAsPercent(level)
        case .external: return "AC"
        }
    }

    var accessibilitySummary: Text {
        switch self {
        case .battery(let level):
            return Text("Battery at \(FormatUtils.formatFractionAsPercent(level))", comment: "Power source accessibility summary. The placeholder is the formatted battery percent.")
        case .external:
            return Text("AC power", comment: "Power source accessibility summary.")
        }
    }
}
