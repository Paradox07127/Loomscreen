import SwiftUI

struct SystemMonitorView: View {
    private var monitor = SystemMonitor.shared
    @State private var powerSource: PowerMonitor.PowerSource = PowerMonitor.shared.currentPowerSource

    var body: some View {
        VStack(spacing: 8) {
            // Container for 4 widgets (2x2 Grid)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                // CPU
                MiniGaugeCard(title: "CPU", value: monitor.cpuUsage, color: colorForPercent(monitor.cpuUsage), icon: "cpu")
                    .accessibilityLabel("CPU usage")
                    .accessibilityValue("\(Int(monitor.cpuUsage)) percent")

                // GPU
                MiniGaugeCard(title: "GPU", value: monitor.gpuUsage, color: colorForPercent(monitor.gpuUsage), icon: "square.stack.3d.up.fill")
                    .accessibilityLabel("GPU usage")
                    .accessibilityValue("\(Int(monitor.gpuUsage)) percent")

                // RAM
                MiniGaugeCard(title: "RAM", value: monitor.memoryPercentage(), color: colorForPercent(monitor.memoryPercentage()), icon: "memorychip")
                    .accessibilityLabel("RAM usage")
                    .accessibilityValue("\(Int(monitor.memoryPercentage())) percent")
                
                // Power
                VStack(spacing: 2) {
                    ZStack {
                        Circle()
                            .trim(from: 0.0, to: 0.75)
                            .stroke(Color.gray.opacity(0.15), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(135))
                        
                        if case .battery(let level) = powerSource {
                            Circle()
                                .trim(from: 0.0, to: CGFloat(level) * 0.75)
                                .stroke(powerStatusColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .rotationEffect(.degrees(135))
                        } else {
                            Circle()
                                .trim(from: 0.0, to: 0.75)
                                .stroke(powerStatusColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .rotationEffect(.degrees(135))
                        }
                        
                        Image(systemName: powerStatusIcon)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(powerStatusColor)
                        
                        VStack(spacing: 0) {
                            Text(powerStatusTextShort)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text(powerStatusTextValue)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .offset(y: 24)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 80)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Power source")
                .accessibilityValue(powerStatusTextShort == "PWR" ? "AC power" : "Battery at \(powerStatusTextValue)")
            }
            .padding(10)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
            
            // FPS, Memory & Thermal Info row
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
                    Text("RAM Usage: \(monitor.formattedMemoryUsage()) / \(monitor.formattedTotalMemory())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 2)
        .frame(maxWidth: 220, alignment: .leading)
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
    
    private var powerStatusIcon: String {
        switch powerSource {
        case .battery(let level):
            if level <= 0.1 { return "battery.0" }
            if level <= 0.25 { return "battery.25" }
            if level <= 0.5 { return "battery.50" }
            if level <= 0.75 { return "battery.75" }
            return "battery.100"
        case .external: return "bolt.fill"
        }
    }

    private var powerStatusTextShort: String {
        switch powerSource {
        case .battery: return "BATT"
        case .external: return "PWR"
        }
    }

    private var powerStatusTextValue: String {
        switch powerSource {
        case .battery(let level): return "\(Int(level * 100))%"
        case .external: return "AC"
        }
    }

    private var powerStatusColor: Color {
        switch powerSource {
        case .battery(let level): 
            if level <= 0.2 { return .red }
            if level <= 0.5 { return .orange }
            return .green
        case .external: return .green
        }
    }
}

struct MiniGaugeCard: View {
    let title: String
    let value: Double
    let color: Color
    let icon: String
    
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // Background Track (270 degrees, from bottom-left to bottom-right)
                Circle()
                    .trim(from: 0.0, to: 0.75)
                    .stroke(Color.gray.opacity(0.15), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(135))
                
                // Foreground Track
                Circle()
                    .trim(from: 0.0, to: CGFloat(min(value / 100.0, 1.0)) * 0.75)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: value)
                
                // Icon in the center
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(color)
                
                // Title and Value in the opening gap at the bottom
                VStack(spacing: 0) {
                    Text(title)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("\(Int(value))%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .offset(y: 24) // Pushes text into the gap
            }
            .aspectRatio(1, contentMode: .fit) // Keep it a perfect square
            .frame(maxWidth: 80) // Set max width to prevent infinite scaling
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
