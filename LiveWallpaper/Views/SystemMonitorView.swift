import SwiftUI

struct SystemMonitorView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var powerSource: PowerMonitor.PowerSource = PowerMonitor.shared.currentPowerSource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BatteryStatusIndicator(powerSource: powerSource)
                .padding(.bottom, 2)

            Divider()

            // CPU
            MetricRow(icon: "cpu", label: "CPU", value: "\(Int(monitor.cpuUsage))%",
                      progress: monitor.cpuUsage / 100, color: colorForPercent(monitor.cpuUsage))

            // GPU
            MetricRow(icon: "gpu", label: "GPU", value: "\(Int(monitor.gpuUsage))%",
                      progress: monitor.gpuUsage / 100, color: colorForPercent(monitor.gpuUsage))

            // Memory
            MetricRow(icon: "memorychip", label: "Memory",
                      value: "\(monitor.formattedMemoryUsage()) / \(monitor.formattedTotalMemory())",
                      progress: monitor.memoryPercentage() / 100,
                      color: colorForPercent(monitor.memoryPercentage()))

            Divider()

            // Thermal + FPS row
            HStack(spacing: 16) {
                // Thermal state
                HStack(spacing: 4) {
                    Image(systemName: thermalIcon)
                        .foregroundStyle(thermalColor)
                        .font(.caption)
                    Text(monitor.thermalStateDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Render FPS
                if monitor.videoFPS > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(monitor.videoFPS)) FPS")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }
        }
        .padding(.all, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
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

    // MARK: - Helpers

    private func colorForPercent(_ pct: Double) -> Color {
        if pct >= 80 { return .red }
        if pct >= 50 { return .orange }
        return .green
    }

    private var thermalIcon: String {
        switch monitor.thermalState {
        case .nominal:  return "thermometer.low"
        case .fair:     return "thermometer.medium"
        case .serious:  return "thermometer.high"
        case .critical: return "thermometer.sun.fill"
        @unknown default: return "thermometer.medium"
        }
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

// MARK: - Metric Row

private struct MetricRow: View {
    let icon: String
    let label: String
    let value: String
    let progress: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 6)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * min(CGFloat(progress), 1.0), height: 6)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Battery Status

struct BatteryStatusIndicator: View {
    var powerSource: PowerMonitor.PowerSource

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: powerStatusIcon)
                    .foregroundStyle(powerStatusColor)
                Text(powerStatusText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
            }

            if case .battery(let level) = powerSource {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 6)
                        Capsule()
                            .fill(batteryColor(level))
                            .frame(width: geo.size.width * CGFloat(level), height: 6)
                    }
                }
                .frame(height: 6)
            }
        }
    }

    private var powerStatusIcon: String {
        switch powerSource {
        case .battery(let level):
            if level <= 0.1 { return "battery.0" }
            if level <= 0.25 { return "battery.25" }
            if level <= 0.5 { return "battery.50" }
            if level <= 0.75 { return "battery.75" }
            return "battery.100"
        case .external:
            return "power.circle.fill"
        }
    }

    private var powerStatusText: String {
        switch powerSource {
        case .battery(let level): return "Battery: \(Int(level * 100))%"
        case .external: return "Connected to Power"
        }
    }

    private var powerStatusColor: Color {
        switch powerSource {
        case .battery(let level): return batteryColor(level)
        case .external: return .green
        }
    }

    private func batteryColor(_ level: Double) -> Color {
        if level <= 0.2 { return .red }
        if level <= 0.5 { return .orange }
        return .green
    }
}

#Preview {
    SystemMonitorView()
        .frame(width: 250)
        .padding()
}
