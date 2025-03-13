import SwiftUI

struct SystemMonitorView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var powerSource: PowerMonitor.PowerSource = PowerMonitor.shared.currentPowerSource
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Power status from BatteryStatusView
            BatteryStatusIndicator(powerSource: powerSource)
                .padding(.bottom, 4)
            
            Divider()
            
            // CPU Usage
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "cpu")
                        .foregroundColor(cpuColor)
                    Text("CPU Usage")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(monitor.cpuUsage))%")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(cpuColor)
                }
                
                // CPU Usage Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: geo.size.width, height: 8)
                            .cornerRadius(4)
                        
                        Rectangle()
                            .fill(cpuColor)
                            .frame(width: geo.size.width * CGFloat(monitor.cpuUsage / 100.0), height: 8)
                            .cornerRadius(4)
                    }
                }
                .frame(height: 8)
            }
            .padding(.bottom, 4)
            
            // Memory Usage
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "memorychip")
                        .foregroundColor(memoryColor)
                    Text("Memory")
                        .font(.subheadline)
                    Spacer()
                    Text("\(monitor.formattedMemoryUsage()) / \(monitor.formattedTotalMemory())")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(memoryColor)
                }
                
                // Memory Usage Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: geo.size.width, height: 8)
                            .cornerRadius(4)
                        
                        Rectangle()
                            .fill(memoryColor)
                            .frame(width: geo.size.width * CGFloat(monitor.memoryPercentage() / 100.0), height: 8)
                            .cornerRadius(4)
                    }
                }
                .frame(height: 8)
            }
            
            Text("Updated every 2 seconds")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.all, 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
        .onAppear {
            monitor.startMonitoring()
            setupPowerMonitoring()
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
    }
    
    private func setupPowerMonitoring() {
        // Update initial power source
        powerSource = PowerMonitor.shared.currentPowerSource
        
        // Subscribe to power source changes
        NotificationCenter.default.addObserver(
            forName: PowerMonitor.powerSourceDidChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let newSource = notification.userInfo?["newSource"] as? PowerMonitor.PowerSource {
                self.powerSource = newSource
            }
        }
    }
    
    private var cpuColor: Color {
        let usage = monitor.cpuUsage
        if usage >= 80 {
            return .red
        } else if usage >= 50 {
            return .orange
        } else {
            return .green
        }
    }
    
    private var memoryColor: Color {
        let usage = monitor.memoryPercentage()
        if usage >= 80 {
            return .red
        } else if usage >= 50 {
            return .orange
        } else {
            return .green
        }
    }
}

// Extracted from BatteryStatusView for integration
struct BatteryStatusIndicator: View {
    var powerSource: PowerMonitor.PowerSource
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top row with icon and text
            HStack {
                Image(systemName: powerStatusIcon)
                    .foregroundColor(powerStatusColor)
                
                Text(powerStatusText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
            }
            
            // Only show battery level indicator when on battery
            if case .battery(let level) = powerSource {
                // Battery level indicator
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: geo.size.width, height: 8)
                            .cornerRadius(4)
                        
                        Rectangle()
                            .fill(batteryLevelColor(level))
                            .frame(width: geo.size.width * CGFloat(level), height: 8)
                            .cornerRadius(4)
                    }
                }
                .frame(height: 8)
            }
        }
    }
    
    // Power status information computed properties
    private var powerStatusIcon: String {
        switch powerSource {
        case .battery(let level):
            if level <= 0.1 {
                return "battery.0"
            } else if level <= 0.25 {
                return "battery.25"
            } else if level <= 0.5 {
                return "battery.50"
            } else if level <= 0.75 {
                return "battery.75"
            } else {
                return "battery.100"
            }
        case .external:
            return "power.circle.fill"
        }
    }
    
    private var powerStatusText: String {
        switch powerSource {
        case .battery(let level):
            return "Battery: \(Int(level * 100))%"
        case .external:
            return "Connected to Power"
        }
    }
    
    private var powerStatusColor: Color {
        switch powerSource {
        case .battery(let level):
            return batteryLevelColor(level)
        case .external:
            return .green
        }
    }
    
    private func batteryLevelColor(_ level: Double) -> Color {
        if level <= 0.2 {
            return .red
        } else if level <= 0.5 {
            return .orange
        } else {
            return .green
        }
    }
}

#Preview {
    SystemMonitorView()
        .frame(width: 250)
        .padding()
}
