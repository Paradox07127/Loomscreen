import SwiftUI

struct SystemMonitorView: View {
    private var monitor = SystemMonitor.shared
    @State private var powerSource: PowerMonitor.PowerSource = PowerMonitor.shared.currentPowerSource
    /// "system" = whole-machine usage (default); "app" = this process only. Synced with menubar panel.
    @AppStorage("Dashboard.RAMScope") private var ramScopeRaw: String = "system"

    private var ramPercent: Double {
        ramScopeRaw == "app" ? monitor.memoryPercentage() : monitor.systemMemoryUsage * 100
    }
    /// All = whole-machine CPU (host_statistics); App = this process (task_threads).
    private var cpuPercent: Double {
        ramScopeRaw == "app" ? monitor.cpuUsage : monitor.systemCpuUsage
    }
    private var ramTitle: String { "RAM" }

    @ViewBuilder
    private func ramScopeButton(label: String, value: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { ramScopeRaw = value }
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
        .accessibilityLabel(value == "system" ? "Show whole-system memory usage" : "Show this app's memory usage")
    }

    private var ramDetailText: String {
        if ramScopeRaw == "app" {
            return "App: \(monitor.formattedMemoryUsage()) / \(monitor.formattedTotalMemory())"
        }
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let usedBytes = UInt64(Double(totalBytes) * monitor.systemMemoryUsage)
        return "Sys: \(FormatUtils.formatBytes(usedBytes)) / \(monitor.formattedTotalMemory())"
    }

    var body: some View {
        VStack(spacing: 8) {
            // RAM scope picker: explicit segmented capsule for "All" (system) vs "App".
            HStack(spacing: 0) {
                ramScopeButton(label: "All", value: "system")
                ramScopeButton(label: "App", value: "app")
            }
            .padding(2)
            .background(Capsule().fill(Color.gray.opacity(0.18)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("RAM scope")

            // 4-widget grid (2x2): CPU / GPU / RAM / Power
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                MiniGaugeCard(title: "CPU", value: cpuPercent, color: colorForPercent(cpuPercent), icon: "cpu")
                    .accessibilityLabel("CPU usage")
                    .accessibilityValue("\(Int(cpuPercent)) percent")

                MiniGaugeCard(title: "GPU", value: monitor.gpuUsage, color: colorForPercent(monitor.gpuUsage), icon: "square.stack.3d.up.fill")
                    .accessibilityLabel("GPU usage")
                    .accessibilityValue("\(Int(monitor.gpuUsage)) percent")

                MiniGaugeCard(title: ramTitle, value: ramPercent, color: colorForPercent(ramPercent), icon: "memorychip")
                    .accessibilityLabel("\(ramTitle) usage")
                    .accessibilityValue("\(Int(ramPercent)) percent")

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
                        Text(monitor.thermalStateDescription)
                            .font(.caption)
                            .foregroundStyle(thermalColor)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(ramDetailText)
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
        // Hard 220pt cap + .clipped() to prevent shadows/subviews from spilling past
        // sidebar's left edge when List(.sidebar) gets stretched.
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

/// Custom 270° ring gauge: background + filled foreground track, icon in center,
/// title + percentage at the bottom gap. Higher visual density than
/// `Gauge.accessoryCircularCapacity` (which has font-size and gap-alignment issues on macOS 26).
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
            // lineWidth=6 matches MiniGaugeCard for consistent ring thickness across the dashboard.
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
