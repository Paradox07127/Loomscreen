import SwiftUI

struct BatteryStatusView: View {
    @State private var powerSource: PowerMonitor.PowerSource = PowerMonitor.shared.currentPowerSource
    private let powerMonitor = PowerMonitor.shared
    
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
            if case .internalBattery(let level) = powerSource {
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
        .padding(.all, 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
        .frame(maxWidth: .infinity) // This makes it take up full width
        .onAppear {
            setupPowerMonitoring()
        }
    }
    
    // Power status information computed properties
    private var powerStatusIcon: String {
        switch powerSource {
        case .internalBattery(let level):
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
        case .externalUnlimited:
            return "power.circle.fill"
        case .externalUPS:
            return "bolt.circle.fill"
        }
    }
    
    private var powerStatusText: String {
        switch powerSource {
        case .internalBattery(let level):
            return "Battery: \(Int(level * 100))%"
        case .externalUnlimited:
            return "Connected to Power"
        case .externalUPS:
            return "Connected to UPS"
        }
    }
    
    private var powerStatusColor: Color {
        switch powerSource {
        case .internalBattery(let level):
            return batteryLevelColor(level)
        case .externalUnlimited:
            return .green
        case .externalUPS:
            return .orange
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
    
    private func setupPowerMonitoring() {
        // Update initial power source
        powerSource = powerMonitor.currentPowerSource
        
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
}

#Preview {
    BatteryStatusView()
        .frame(width: 250)
        .padding()
}
