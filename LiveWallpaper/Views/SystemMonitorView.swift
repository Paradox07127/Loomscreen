import SwiftUI

struct SystemMonitorView: View {
    private var monitor = SystemMonitor.shared
    @State private var powerSource: PowerMonitor.PowerSource = PowerMonitor.shared.currentPowerSource

    var body: some View {
        VStack(spacing: 8) {
            // 4-widget grid (2x2): CPU / GPU / RAM / Power
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                MiniGaugeCard(title: "CPU", value: monitor.cpuUsage, color: colorForPercent(monitor.cpuUsage), icon: "cpu")
                    .accessibilityLabel("CPU usage")
                    .accessibilityValue("\(Int(monitor.cpuUsage)) percent")

                MiniGaugeCard(title: "GPU", value: monitor.gpuUsage, color: colorForPercent(monitor.gpuUsage), icon: "square.stack.3d.up.fill")
                    .accessibilityLabel("GPU usage")
                    .accessibilityValue("\(Int(monitor.gpuUsage)) percent")

                MiniGaugeCard(title: "RAM", value: monitor.memoryPercentage(), color: colorForPercent(monitor.memoryPercentage()), icon: "memorychip")
                    .accessibilityLabel("RAM usage")
                    .accessibilityValue("\(Int(monitor.memoryPercentage())) percent")

                PowerStatusCard(powerSource: powerSource)
                    .accessibilityLabel("Power source")
                    .accessibilityValue(powerSource.accessibilitySummary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)

            // FPS, Thermal, RAM detail row
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if monitor.videoFPS > 0 {
                            Text("\(Int(monitor.videoFPS)) FPS")
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
                        Text(monitor.thermalStateDescription)
                            .font(.caption)
                            .foregroundStyle(thermalColor)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("RAM: \(monitor.formattedMemoryUsage()) / \(monitor.formattedTotalMemory())")
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
        // 硬性 220 宽度上限 + .clipped()，防止 List(.sidebar) 拉伸时阴影/
        // 子视图越过 sidebar 左边界。`maxWidth: .infinity` 会被 List 默认
        // row inset 拉至负偏移，反而触发溢出。
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
}

// MARK: - MiniGaugeCard

/// 自定义 270° 圆环 gauge：背景轨道 + 前景轨道按比例填充，中央放图标，
/// 圆环底部缺口处放 title 与百分比。该样式视觉密度优于
/// `Gauge.accessoryCircularCapacity`（后者在 macOS 26 字号偏大、缺口对齐失真）。
struct MiniGaugeCard: View {
    let title: String
    let value: Double
    let color: Color
    let icon: String

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.75)
                .stroke(Color.gray.opacity(0.15), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(135))

            Circle()
                .trim(from: 0.0, to: CGFloat(min(value / 100.0, 1.0)) * 0.75)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: value)

            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)

            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("\(Int(value))%")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
            .offset(y: 18)
        }
        .frame(width: 54, height: 54)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PowerStatusCard

struct PowerStatusCard: View {
    let powerSource: PowerMonitor.PowerSource

    var body: some View {
        ZStack {
            // 与 MiniGaugeCard 保持一致的 lineWidth=6，确保 sidebar 仪表盘
            // 四个圆环视觉粗细统一。
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
                Text(powerSource.shortLabel)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(powerSource.valueLabel)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
            .offset(y: 18)
        }
        .frame(width: 54, height: 54)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case .battery(let level): return "\(Int(level * 100))%"
        case .external: return "AC"
        }
    }

    var accessibilitySummary: String {
        switch self {
        case .battery(let level): return "Battery at \(Int(level * 100)) percent"
        case .external: return "AC power"
        }
    }
}
