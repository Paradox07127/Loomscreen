import SwiftUI
import AppKit
import AVKit

struct ContentView: View {
    @EnvironmentObject private var screenManager: ScreenManager
    @State private var selectedNavigation: Navigation?
    
    init(initialNavigation: Navigation? = nil) {
        self._selectedNavigation = State(initialValue: initialNavigation)
    }
    
    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selectedNavigation)
                .onReceive(NotificationCenter.default.publisher(for: .init("SelectScreenInSettings"))) { notification in
                    if let screenID = notification.userInfo?["screenID"] as? CGDirectDisplayID {
                        selectedNavigation = .screen(screenID)
                    }
                }
        } detail: {
            DetailContent(selection: selectedNavigation)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack {
                    Image(systemName: "photo.on.rectangle.fill")
                        .font(.title2)
                        .imageScale(.large)
                        .foregroundColor(.accentColor)
                    
                    Text("LiveWallpaper")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                .padding(.top, 6)
            }
        }
    }
}

// MARK: - Navigation Enum
enum Navigation: Hashable {
    case general
    case screen(CGDirectDisplayID)
    
    var title: String {
        switch self {
        case .general:
            return "General Settings"
        case .screen(let id):
            return "Display \(id)"
        }
    }
    
    var icon: String {
        switch self {
        case .general:
            return "gearshape.fill"
        case .screen:
            return "display"
        }
    }
}

// MARK: - Sidebar View
struct Sidebar: View {
    @Binding var selection: Navigation?
    @EnvironmentObject private var screenManager: ScreenManager
    @State private var isRefreshing = false
    
    var body: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: Navigation.general) {
                    HStack {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.blue)
                            .imageScale(.large)
                            .frame(width: 24, height: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("General Settings")
                                .fontWeight(.medium)
                            
                            Text("Global app preferences")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Section {
                HStack {
                    Text("Displays")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button(action: refreshDisplays) {
                        Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                            .imageScale(.medium)
                            .rotationEffect(isRefreshing ? .degrees(360) : .degrees(0))
                            .animation(isRefreshing ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh display list")
                }
                .padding(.vertical, 6)
                
                if screenManager.screens.isEmpty {
                    HStack {
                        Image(systemName: "display.slash")
                            .foregroundColor(.secondary)
                        Text("No displays detected")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                } else {
                    ForEach(screenManager.screens, id: \.id) { screen in
                        NavigationLink(value: Navigation.screen(screen.id)) {
                            ScreenRow(screen: screen)
                        }
                    }
                }
            }
            
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Battery Status")
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .padding(.top, 6)
                    
                    BatteryStatusView()
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 250)
    }
    
    private func refreshDisplays() {
        withAnimation {
            isRefreshing = true
        }
        
        screenManager.refreshScreens()
        
        // Reset the animation after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation {
                isRefreshing = false
            }
        }
    }
}

// MARK: - Battery Status View
struct BatteryStatusView: View {
    @State private var powerSource: PowerMonitor.PowerSource = PowerMonitor.shared.currentPowerSource
    private let powerMonitor = PowerMonitor.shared
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: powerStatusIcon)
                .font(.title3)
                .foregroundColor(powerStatusColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(powerStatusText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if case .internalBattery(let level) = powerSource {
                    // Battery level indicator
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: geo.size.width, height: 6)
                            
                            RoundedRectangle(cornerRadius: 2)
                                .fill(batteryLevelColor(level))
                                .frame(width: geo.size.width * CGFloat(level), height: 6)
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
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

// MARK: - Screen Row
struct ScreenRow: View {
    @ObservedObject var screen: Screen
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 32, height: 24)
                
                Image(systemName: screen.videoPlayer != nil ? "display.and.arrow.down" : "display")
                    .foregroundColor(screen.videoPlayer != nil ? .blue : .gray)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(screen.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if screen.videoPlayer != nil {
                        HStack(spacing: 2) {
                            Circle()
                                .fill(screen.videoPlayer?.isPlaying ?? false ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            
                            Text(screen.videoPlayer?.isPlaying ?? false ? "Playing" : "Paused")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail Content
struct DetailContent: View {
    let selection: Navigation?
    @EnvironmentObject private var screenManager: ScreenManager
    
    var body: some View {
        Group {
            switch selection {
            case .general:
                GeneralSettingsView()
                    .transition(.opacity)
                
            case .screen(let screenId):
                if let screen = screenManager.screens.first(where: { $0.id == screenId }) {
                    ScreenDetailView(screen: screen)
                        .transition(.opacity)
                } else {
                    EmptyStateView(
                        icon: "display.trianglebadge.exclamationmark",
                        title: "Display Not Found",
                        message: "The selected display is no longer available."
                    )
                }
                
            case .none:
                EmptyStateView(
                    icon: "arrow.left.circle",
                    title: "Select a Display",
                    message: "Choose a display from the sidebar to configure your live wallpaper."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .animation(.easeInOut, value: selection)
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.7))
            
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
