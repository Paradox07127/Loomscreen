import SwiftUI

struct GeneralSettingsView: View {
    @Environment(ScreenManager.self) private var screenManager
    @State private var globalPauseOnBattery: Bool
    @State private var startOnLogin: Bool
    @State private var preservePlaybackOnLock: Bool
    @State private var minimumBatteryLevel: Double?
    @State private var useBatteryThreshold: Bool
    @State private var pauseOnFullScreen: Bool
    @State private var showInDock: Bool

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
        _showInDock = State(initialValue: settings.showInDock)
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            powerTab
                .tabItem { Label("Power", systemImage: "bolt.batteryblock") }

            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "command") }

            WeatherLocationSettingsView()
                .tabItem { Label("Weather", systemImage: "cloud.sun") }

            WPECacheManagementView()
                .tabItem { Label("Cache", systemImage: "internaldrive") }

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Set min size only; capping maxWidth would clip content in narrow detail panes.
        // Grouped Form whitespace is absorbed inside Sections (inline Reset button +
        // compact card layout) rather than by constraining overall width.
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

    // MARK: - General Tab

    @ViewBuilder
    private var generalTab: some View {
        Form {
            Section {
                SettingRow(icon: "power.circle.fill", iconColor: .green, title: "Start at login", subtitle: "Automatically launch LiveWallpaper when you log in") {
                    Toggle("", isOn: $startOnLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: startOnLogin) { _, _ in updateGlobalSettings() }
                        .accessibilityLabel("Start at login")
                        .accessibilityHint("Automatically launch LiveWallpaper when you log in")
                }

                SettingRow(icon: "lock.display", iconColor: .blue, title: "Refresh desktop picture on lock", subtitle: "When your Mac locks, capture the current frame for screens with Desktop Picture enabled") {
                    Toggle("", isOn: $preservePlaybackOnLock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: preservePlaybackOnLock) { _, _ in updateGlobalSettings() }
                        .accessibilityLabel("Refresh desktop picture on lock")
                        .accessibilityHint("When your Mac locks, capture the current frame for screens with Desktop Picture enabled")
                }

                SettingRow(icon: "macwindow.badge.plus", iconColor: .purple, title: "Pause on full-screen apps", subtitle: "Automatically pause wallpapers when a full-screen app is active") {
                    Toggle("", isOn: $pauseOnFullScreen)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: pauseOnFullScreen) { _, _ in updateGlobalSettings() }
                        .accessibilityLabel("Pause on full-screen apps")
                        .accessibilityHint("Automatically pause wallpapers when a full-screen app is active")
                }

                SettingRow(icon: "dock.rectangle", iconColor: .indigo, title: "Show in Dock", subtitle: "Make the app visible in the Dock and Cmd-Tab switcher") {
                    Toggle("", isOn: $showInDock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: showInDock) { _, _ in updateGlobalSettings() }
                        .accessibilityLabel("Show in Dock")
                        .accessibilityHint("Toggles whether the app appears in the Dock and the Cmd-Tab switcher")
                }
            } header: {
                Text("Behavior")
            }

            Section {
                HStack(spacing: 16) {
                    Button(action: validateConfigurations) {
                        Label("Validate Settings", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Validate settings")
                    .accessibilityHint("Checks all screen configurations for errors")

                    Button(action: { screenManager.reloadAllScreens() }) {
                        Label("Reload All Screens", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Reload all screens")
                    .accessibilityHint("Refreshes wallpaper playback on all connected screens")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.vertical, 4)

                HStack {
                    Spacer()
                    Button("Show Welcome Tour") {
                        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                            appDelegate.showOnboarding()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Show welcome tour")
                    .accessibilityHint("Replays the initial onboarding flow")
                    Spacer()
                }
                .padding(.vertical, 4)

                // Reset embedded in Section body alongside Validate/Reload (replacing
                // the old footer placement) so it sits tight under the troubleshooting
                // tools without Section.footer's large vertical inset.
                HStack {
                    Spacer()
                    Button("Reset All Settings to Default") {
                        showingResetAlert = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Reset all settings to default")
                    .accessibilityHint("Erases all configurations and restores factory defaults")
                    Spacer()
                }
                .padding(.vertical, 4)
            } header: {
                Text("Troubleshooting")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Power Tab

    @ViewBuilder
    private var powerTab: some View {
        Form {
            Section {
                SettingRow(icon: "bolt.circle.fill", iconColor: .yellow, title: "Pause on battery", subtitle: "Switch wallpapers to a static frame when your Mac is unplugged") {
                    Toggle("", isOn: $globalPauseOnBattery)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: globalPauseOnBattery) { _, _ in updateGlobalSettings() }
                        .accessibilityLabel("Pause on battery")
                        .accessibilityHint("Switch wallpapers to a static frame when your Mac is unplugged")
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
                                minimumBatteryLevel = 0.2
                            }
                            updateGlobalSettings()
                        }
                        .accessibilityLabel("Use battery threshold")
                        .accessibilityHint("Pause videos when battery drops below a specific level")
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
                        .accessibilityLabel("Minimum battery level")
                        .accessibilityValue("\(Int((minimumBatteryLevel ?? 0.2) * 100)) percent")
                        .accessibilityHint("Set the battery level below which wallpapers will pause")
                    }
                    .padding(.leading, 52)
                    .padding(.bottom, 8)
                    .disabled(!useBatteryThreshold)
                    .animation(.snappy(duration: 0.2), value: useBatteryThreshold)
                }
            } header: {
                Text("Battery Threshold")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About Tab

    @ViewBuilder
    private var aboutTab: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)

            Image(systemName: "play.rectangle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 4) {
                Text("LiveWallpaper")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(versionString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("Built with SwiftUI, Metal, and Liquid Glass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(version) (\(build))"
    }

    // MARK: - Settings Persistence

    private func updateGlobalSettings() {
        // Read current persisted state so toggling unrelated fields does NOT
        // wipe Wallpaper Engine import history (or any other field added
        // outside this form). Only override what this view actually owns.
        var settings = SettingsManager.shared.loadGlobalSettings()
        let dockChanged = settings.showInDock != showInDock
        settings.globalPauseOnBattery = globalPauseOnBattery
        settings.preservePlaybackOnLock = preservePlaybackOnLock
        settings.startOnLogin = startOnLogin
        settings.minimumBatteryLevel = useBatteryThreshold ? minimumBatteryLevel : nil
        settings.pauseOnFullScreen = pauseOnFullScreen
        settings.showInDock = showInDock
        SettingsManager.shared.saveGlobalSettings(settings)
        screenManager.handleGlobalSettingsChanged()
        if dockChanged {
            NotificationCenter.default.post(name: .dockVisibilityDidChange, object: nil)
        }
    }

    private func resetAllSettings() {
        SettingsManager.shared.cleanAllSettings()

        globalPauseOnBattery = false
        startOnLogin = false
        preservePlaybackOnLock = false
        minimumBatteryLevel = nil
        useBatteryThreshold = false
        pauseOnFullScreen = true
        showInDock = false

        // Reset wipes Dock visibility, weather location preference, and
        // shortcut bindings. Broadcast all three so the AppDelegate, weather
        // service, and global shortcut manager re-sync without a relaunch.
        NotificationCenter.default.post(name: .dockVisibilityDidChange, object: nil)
        NotificationCenter.default.post(name: .globalShortcutsDidChange, object: nil)
        NotificationCenter.default.post(name: .weatherLocationPreferenceDidChange, object: nil)
        screenManager.handleGlobalSettingsChanged()
        screenManager.resetAllWallpaperSessions()
        screenManager.refreshScreens(preserveRuntimeSessions: false)
    }

    private func validateConfigurations() {
        let (valid, invalid) = screenManager.validateAllConfigurations()

        let connectedScreens = Set(screenManager.screens.map(\.id))
        let allConfigurations = SettingsManager.shared.loadConfigurations()
        let configuredScreenIDs = Set(allConfigurations.map { $0.screenID })

        let disconnectedConfigs = configuredScreenIDs.subtracting(connectedScreens)
        let disconnectedInvalid = disconnectedConfigs.count

        let connectedInvalid = invalid - disconnectedInvalid

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
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray, lineWidth: 2)
                    .frame(width: 160, height: 30)

                RoundedRectangle(cornerRadius: 3)
                    .fill(batteryColor)
                    .padding(3)
                    .frame(width: 160 * level, height: 30)
            }

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray)
                .frame(width: 4, height: 16)
        }
    }
}

#Preview {
    GeneralSettingsView()
}
