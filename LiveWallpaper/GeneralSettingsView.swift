import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var screenManager: ScreenManager
    @State private var globalPauseOnBattery: Bool
    @State private var startOnLogin: Bool
    @State private var preservePlaybackOnLock: Bool
    @State private var minimumBatteryLevel: Double?
    @State private var useBatteryThreshold: Bool
    
    @State private var showingResetAlert = false
    @State private var showingValidationResults = false
    @State private var validationMessage = ""
    @State private var validationIcon = ""
    @State private var validationColor: Color = .green
    
    init() {
        let settings = SettingsManager.shared.loadGlobalSettings()
        _globalPauseOnBattery = State(initialValue: settings.globalPauseOnBattery)
        _startOnLogin = State(initialValue: settings.startOnLogin)
        _preservePlaybackOnLock = State(initialValue: settings.preservePlaybackOnLock)
        _minimumBatteryLevel = State(initialValue: settings.minimumBatteryLevel)
        _useBatteryThreshold = State(initialValue: settings.minimumBatteryLevel != nil)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                welcomeSection
                powerSettingsSection
                startupSection
                configValidationSection
                resetSettingsSection
                
                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .alert("Reset Settings", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset All", role: .destructive) {
                resetAllSettings()
            }
        } message: {
            Text("This will reset all settings including screen configurations. This action cannot be undone.")
        }
        .alert("Configuration Validation", isPresented: $showingValidationResults) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationMessage)
        }
    }
    
    private var welcomeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LiveWallpaper Settings")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Configure global settings that apply to all your displays")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    private var powerSettingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "bolt.circle.fill")
                        .font(.title2)
                        .foregroundColor(.yellow)
                    
                    Text("Power Management")
                        .font(.headline)
                }
                .padding(.bottom, 4)
                
                VStack(alignment: .leading, spacing: 16) {
                    // Global pause on battery
                    Toggle(isOn: $globalPauseOnBattery) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pause all videos when on battery")
                                .font(.body)
                            
                            Text("Automatically pauses all wallpapers when your Mac is unplugged")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: globalPauseOnBattery) { oldValue, newValue in
                        updateGlobalSettings()
                        screenManager.handleGlobalPauseOnBatteryChange(newValue)
                    }
                    
                    Divider()
                    
                    // Battery threshold settings
                    Toggle(isOn: $useBatteryThreshold) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Use battery level threshold")
                                .font(.body)
                            
                            Text("Pause videos when battery drops below a specific level")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: useBatteryThreshold) { oldValue, newValue in
                        if !newValue {
                            minimumBatteryLevel = nil
                        } else if minimumBatteryLevel == nil {
                            minimumBatteryLevel = 0.2 // Default to 20%
                        }
                        updateGlobalSettings()
                    }
                    
                    if useBatteryThreshold {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Spacer()
                                BatteryLevelIndicator(level: minimumBatteryLevel ?? 0.2)
                                Spacer()
                            }
                            
                            HStack {
                                Text("Pause when battery below:")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                
                                Text("\(Int((minimumBatteryLevel ?? 0.2) * 100))%")
                                    .font(.headline)
                                    .foregroundColor(
                                        (minimumBatteryLevel ?? 0.2) < 0.2 ? .red :
                                            (minimumBatteryLevel ?? 0.2) < 0.3 ? .orange : .green
                                    )
                                    .frame(width: 44, alignment: .trailing)
                            }
                            
                            Slider(value: Binding(
                                get: { minimumBatteryLevel ?? 0.2 },
                                set: { newValue in
                                    minimumBatteryLevel = newValue
                                    updateGlobalSettings()
                                }
                            ), in: 0.05...0.5, step: 0.05)
                        }
                        .padding(.leading, 24)
                        .disabled(!useBatteryThreshold)
                        .animation(.easeOut, value: useBatteryThreshold)
                    }
                    
                    Divider()
                    
                    // Screen lock behavior
                    Toggle(isOn: $preservePlaybackOnLock) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Preserve playback state when screen is locked")
                                .font(.body)
                            
                            Text("Keep videos playing when your screen is locked")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: preservePlaybackOnLock) { oldValue, newValue in
                        updateGlobalSettings()
                    }
                }
            }
            .padding(16)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
    
    private var startupSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "power.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                    
                    Text("Startup Options")
                        .font(.headline)
                }
                .padding(.bottom, 4)
                
                Toggle(isOn: $startOnLogin) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start at login")
                            .font(.body)
                        
                        Text("LiveWallpaper will automatically start when you log in")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: startOnLogin) { oldValue, newValue in
                    updateGlobalSettings()
                }
            }
            .padding(16)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
    
    private var configValidationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                    
                    Text("Configuration Management")
                        .font(.headline)
                }
                .padding(.bottom, 4)
                
                Text("Check if your video configurations are valid and reload screens if needed")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 16) {
                    Button(action: {
                        validateConfigurations()
                    }) {
                        Label("Validate Configurations", systemImage: "doc.text.magnifyingglass")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button(action: {
                        screenManager.reloadAllScreens()
                    }) {
                        Label("Reload All Screens", systemImage: "arrow.triangle.2.circlepath")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
    
    private var resetSettingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                    
                    Text("Reset Settings")
                        .font(.headline)
                }
                .padding(.bottom, 4)
                
                Text("If you're experiencing issues, you can reset all settings to their defaults")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Button(action: {
                    showingResetAlert = true
                }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle")
                        Text("Reset All Settings")
                    }
                    .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
            .padding(16)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
    
    private func updateGlobalSettings() {
        let settings = GlobalSettings(
            globalPauseOnBattery: globalPauseOnBattery,
            preservePlaybackOnLock: preservePlaybackOnLock,
            startOnLogin: startOnLogin,
            minimumBatteryLevel: useBatteryThreshold ? minimumBatteryLevel : nil
        )
        SettingsManager.shared.saveGlobalSettings(settings)
    }
    
    private func resetAllSettings() {
        SettingsManager.shared.cleanAllSettings()
        
        // Reset UI state
        globalPauseOnBattery = true
        startOnLogin = false
        preservePlaybackOnLock = false
        minimumBatteryLevel = nil
        useBatteryThreshold = false
        
        // Refresh screens in the screen manager
        screenManager.refreshScreens()
    }
    
    private func validateConfigurations() {
        // Get validation results from the screen manager
        let (valid, invalid) = screenManager.validateAllConfigurations()
        
        // Track connected vs disconnected screens
        let connectedScreens = Set(screenManager.screens.map(\.id))
        let allConfigurations = SettingsManager.shared.loadConfigurations()
        let configuredScreenIDs = Set(allConfigurations.map { $0.screenID })
        
        let disconnectedConfigs = configuredScreenIDs.subtracting(connectedScreens)
        let disconnectedInvalid = disconnectedConfigs.count
        
        let connectedInvalid = invalid - disconnectedInvalid
        
        // Create detailed validation message
        if invalid == 0 {
            validationMessage = "✅ All \(valid) configurations are valid."
            validationIcon = "checkmark.circle.fill"
            validationColor = .green
        } else {
            validationMessage = "Validation complete: \(valid) of \(valid + invalid) configurations are valid.\n\n"
            
            if disconnectedInvalid > 0 {
                validationMessage += "• \(disconnectedInvalid) invalid configurations are for disconnected screens.\n"
            }
            
            if connectedInvalid > 0 {
                validationMessage += "• \(connectedInvalid) invalid configurations are for connected screens.\n"
                validationMessage += "\nYou may need to reconfigure these screens."
            }
            
            validationIcon = "exclamationmark.triangle.fill"
            validationColor = .orange
        }
        
        showingValidationResults = true
    }
}

struct BatteryLevelIndicator: View {
    let level: Double
    
    var batteryColor: Color {
        if level < 0.2 {
            return .red
        } else if level < 0.3 {
            return .orange
        } else {
            return .green
        }
    }
    
    var body: some View {
        HStack(spacing: 2) {
            // Battery body
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray, lineWidth: 2)
                    .frame(width: 160, height: 30)
                
                RoundedRectangle(cornerRadius: 3)
                    .fill(batteryColor)
                    .padding(3)
                    .frame(width: 160 * level, height: 30)
            }
            
            // Battery terminal
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray)
                .frame(width: 4, height: 16)
        }
    }
}
