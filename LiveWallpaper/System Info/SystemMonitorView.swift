import SwiftUI

struct SystemMonitorView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        }
        .onDisappear {
            monitor.stopMonitoring()
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

#Preview {
    SystemMonitorView()
        .frame(width: 250)
        .padding()
}
