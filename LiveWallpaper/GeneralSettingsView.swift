import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var screenManager: ScreenManager
    @State private var globalPauseOnBattery: Bool
    @State private var showingResetAlert = false
    
    init() {
        _globalPauseOnBattery = State(initialValue: SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                powerSettingsSection
                resetSettingsSection
                Spacer()
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
    }
    
    private var powerSettingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Power Settings", systemImage: "bolt.circle")
                    .font(.headline)
                
                Toggle("Pause all videos when on battery", isOn: $globalPauseOnBattery)
                    .onChange(of: globalPauseOnBattery) { oldValue, newValue in
                        let settings = GlobalSettings(globalPauseOnBattery: newValue)
                        SettingsManager.shared.saveGlobalSettings(settings)
                        screenManager.handleGlobalPauseOnBatteryChange(newValue)
                    }
                
                Text("This setting affects all screens")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
        }
    }
    
    private var resetSettingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Reset Settings", systemImage: "arrow.counterclockwise.circle")
                    .font(.headline)
                
                Button(action: {
                    showingResetAlert = true
                }) {
                    Text("Reset All Settings")
                        .foregroundColor(.red)
                }
            }
            .padding(16)
        }
    }
    
    private func resetAllSettings() {
        SettingsManager.shared.cleanAllSettings()
        globalPauseOnBattery = true  // Reset to default
        screenManager.refreshScreens()
    }
}
