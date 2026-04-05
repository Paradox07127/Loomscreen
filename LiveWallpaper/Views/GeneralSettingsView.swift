import SwiftUI

struct GeneralSettingsView: View {
    @Environment(ScreenManager.self) private var screenManager
    @State private var globalPauseOnBattery: Bool
    @State private var startOnLogin: Bool
    @State private var preservePlaybackOnLock: Bool
    @State private var minimumBatteryLevel: Double?
    @State private var useBatteryThreshold: Bool
    @State private var pauseOnFullScreen: Bool
    @State private var batteryResolutionCap: Bool
    
    @State private var showingResetAlert = false
    @State private var showingValidationResults = false
    @State private var validationMessage = ""
    
    init() {
        let settings = SettingsManager.shared.loadGlobalSettings()
        _globalPauseOnBattery = State(initialValue: settings.globalPauseOnBattery)
        _startOnLogin = State(initialValue: settings.startOnLogin)
        _preservePlaybackOnLock = State(initialValue: settings.preservePlaybackOnLock)
        _minimumBatteryLevel = State(initialValue: settings.minimumBatteryLevel)
        _useBatteryThreshold = State(initialValue: settings.minimumBatteryLevel != nil)
        _pauseOnFullScreen = State(initialValue: settings.pauseOnFullScreen)
        _batteryResolutionCap = State(initialValue: settings.batteryResolutionCap)
    }
    
    var body: some View {
        TabView {
            // General Tab
            Form {
                Section {
                    SettingRow(icon: "power.circle.fill", iconColor: .green, title: "Start at login", subtitle: "Automatically launch LiveWallpaper when you log in") {
                        Toggle("", isOn: $startOnLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: startOnLogin) { _, _ in updateGlobalSettings() }
                    }
                    
                    SettingRow(icon: "lock.display", iconColor: .blue, title: "Preserve playback on lock screen", subtitle: "Keep videos playing when your screen is locked") {
                        Toggle("", isOn: $preservePlaybackOnLock)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: preservePlaybackOnLock) { _, _ in updateGlobalSettings() }
                    }
                    
                    SettingRow(icon: "macwindow.badge.plus", iconColor: .purple, title: "Pause on full-screen apps", subtitle: "Automatically pause wallpapers when a full-screen app is active") {
                        Toggle("", isOn: $pauseOnFullScreen)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: pauseOnFullScreen) { _, _ in updateGlobalSettings() }
                    }
                } header: {
                    Text("Behavior")
                }
                
                Section {
                    HStack(spacing: 16) {
                        Button(action: {
                            validateConfigurations()
                        }) {
                            Label("Validate Settings", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        
                        Button(action: {
                            screenManager.reloadAllScreens()
                        }) {
                            Label("Reload All Screens", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.vertical, 8)
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    HStack {
                        Spacer()
                        Button("Reset All Settings to Default") {
                            showingResetAlert = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .padding(.top, 16)
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            
            // Power Management Tab
            Form {
                Section {
                    SettingRow(icon: "bolt.circle.fill", iconColor: .yellow, title: "Pause on battery", subtitle: "Automatically pause all wallpapers when your Mac is unplugged") {
                        Toggle("", isOn: $globalPauseOnBattery)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: globalPauseOnBattery) { _, newValue in
                                updateGlobalSettings()
                                screenManager.handleGlobalPauseOnBatteryChange(newValue)
                            }
                    }
                    
                    SettingRow(icon: "battery.100.bolt", iconColor: .green, title: "Reduce quality on battery", subtitle: "Lower decode resolution when running on battery to save power") {
                        Toggle("", isOn: $batteryResolutionCap)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: batteryResolutionCap) { _, _ in updateGlobalSettings() }
                    }
                } header: {
                    Text("Power Saving")
                }
                
                Section {
                    SettingRow(icon: "battery.50", iconColor: .orange, title: "Use battery threshold", subtitle: "Pause videos when battery drops below a specific level") {
                        Toggle("", isOn: $useBatteryThreshold)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: useBatteryThreshold) { _, newValue in
                                if !newValue {
                                    minimumBatteryLevel = nil
                                } else if minimumBatteryLevel == nil {
                                    minimumBatteryLevel = 0.2 // Default to 20%
                                }
                                updateGlobalSettings()
                            }
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
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(Int((minimumBatteryLevel ?? 0.2) * 100))%")
                                    .font(.headline)
                                    .foregroundStyle(
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
                        .padding(.leading, 52)
                        .padding(.bottom, 8)
                        .disabled(!useBatteryThreshold)
                        .animation(.easeOut, value: useBatteryThreshold)
                    }
                } header: {
                    Text("Battery Threshold")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Power", systemImage: "bolt.batteryblock")
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
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
    
    private func updateGlobalSettings() {
        let settings = GlobalSettings(
            globalPauseOnBattery: globalPauseOnBattery,
            preservePlaybackOnLock: preservePlaybackOnLock,
            startOnLogin: startOnLogin,
            minimumBatteryLevel: useBatteryThreshold ? minimumBatteryLevel : nil,
            pauseOnFullScreen: pauseOnFullScreen,
            batteryResolutionCap: batteryResolutionCap
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
        pauseOnFullScreen = true
        batteryResolutionCap = true
        
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
        } else {
            validationMessage = "Validation complete: \(valid) of \(valid + invalid) configurations are valid.\n\n"
            
            if disconnectedInvalid > 0 {
                validationMessage += "• \(disconnectedInvalid) invalid configurations are for disconnected screens.\n"
            }
            
            if connectedInvalid > 0 {
                validationMessage += "• \(connectedInvalid) invalid configurations are for connected screens.\n"
                validationMessage += "\nYou may need to reconfigure these screens."
            }
            
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

#Preview {
    GeneralSettingsView()
}