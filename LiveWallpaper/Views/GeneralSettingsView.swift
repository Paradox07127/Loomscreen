import SwiftUI
import AppKit

struct GeneralSettingsView: View {
    @Environment(ScreenManager.self) private var screenManager
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRawValue = AppLanguagePreference.system.rawValue
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
        .background(Color(NSColor.underPageBackgroundColor))
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
            Text(verbatim: validationMessage)
        }
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalTab: some View {
        settingsForm {
            Section {
                SettingRow(icon: "globe", iconColor: .teal, title: "Language", subtitle: "Choose the display language used by LiveWallpaper") {
                    Picker("", selection: appLanguageSelection) {
                        ForEach(AppLanguagePreference.allCases) { language in
                            Text(language.titleKey).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .accessibilityLabel(Text("Language"))
                    .accessibilityHint(Text("Choose the display language used by LiveWallpaper"))
                }

                SettingRow(icon: "power.circle.fill", iconColor: .green, title: "Start at login", subtitle: "Automatically launch LiveWallpaper when you log in") {
                    Toggle("", isOn: $startOnLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: startOnLogin) { _, _ in updateGlobalSettings() }
                        .accessibilityLabel(Text("Start at login"))
                        .accessibilityHint(Text("Automatically launch LiveWallpaper when you log in"))
                }

                SettingRow(icon: "lock.display", iconColor: .blue, title: "Refresh desktop picture on lock", subtitle: "When your Mac locks, capture the current frame for screens with Desktop Picture enabled") {
                    Toggle("", isOn: $preservePlaybackOnLock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: preservePlaybackOnLock) { _, _ in updateGlobalSettings() }
                        .accessibilityLabel(Text("Refresh desktop picture on lock"))
                        .accessibilityHint(Text("When your Mac locks, capture the current frame for screens with Desktop Picture enabled"))
                }

                SettingRow(icon: "macwindow.badge.plus", iconColor: .purple, title: "Pause on full-screen apps", subtitle: "Automatically pause wallpapers when a full-screen app is active") {
                    Toggle("", isOn: $pauseOnFullScreen)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: pauseOnFullScreen) { _, _ in updateGlobalSettings() }
                        .accessibilityLabel(Text("Pause on full-screen apps"))
                        .accessibilityHint(Text("Automatically pause wallpapers when a full-screen app is active"))
                }

                SettingRow(icon: "dock.rectangle", iconColor: .indigo, title: "Show in Dock", subtitle: "Make the app visible in the Dock and Cmd-Tab switcher") {
                    Toggle("", isOn: $showInDock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: showInDock) { _, _ in updateGlobalSettings() }
                        .accessibilityLabel(Text("Show in Dock"))
                        .accessibilityHint(Text("Toggles whether the app appears in the Dock and the Cmd-Tab switcher"))
                }
            } header: {
                Text("Behavior")
            }

            Section {
                troubleshootingActions
            } header: {
                Text("Troubleshooting")
            }
        }
    }

    // MARK: - Power Tab

    @ViewBuilder
    private var powerTab: some View {
        settingsForm {
            Section {
                SettingRow(icon: "bolt.circle.fill", iconColor: .yellow, title: "Pause on battery", subtitle: "Switch wallpapers to a static frame when your Mac is unplugged") {
                    Toggle("", isOn: $globalPauseOnBattery)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: globalPauseOnBattery) { _, _ in updateGlobalSettings() }
                        .accessibilityLabel(Text("Pause on battery"))
                        .accessibilityHint(Text("Switch wallpapers to a static frame when your Mac is unplugged"))
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
                        .accessibilityLabel(Text("Use battery threshold"))
                        .accessibilityHint(Text("Pause videos when battery drops below a specific level"))
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
                            Text(verbatim: FormatUtils.formatFractionAsPercent(minimumBatteryLevel ?? 0.2))
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
                        .accessibilityLabel(Text("Minimum battery level"))
                        .accessibilityValue(Text(verbatim: FormatUtils.formatFractionAsPercent(minimumBatteryLevel ?? 0.2)))
                        .accessibilityHint(Text("Set the battery level below which wallpapers will pause"))
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

                Text(verbatim: versionString)
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
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, DesignTokens.Settings.formHorizontalMargin, for: .scrollContent)
        .contentMargins(.vertical, DesignTokens.Settings.formVerticalMargin, for: .scrollContent)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private var troubleshootingActions: some View {
        VStack(spacing: DesignTokens.Settings.actionGridSpacing) {
            HStack(spacing: DesignTokens.Settings.actionGridSpacing) {
                settingsActionButton(
                    title: "Validate Settings",
                    accessibilityLabel: "Validate settings",
                    accessibilityHint: "Checks all screen configurations for errors",
                    systemImage: "doc.text.magnifyingglass",
                    action: validateConfigurations
                )

                settingsActionButton(
                    title: "Reload All Screens",
                    accessibilityLabel: "Reload all screens",
                    accessibilityHint: "Refreshes wallpaper playback on all connected screens",
                    systemImage: "arrow.triangle.2.circlepath",
                    action: { screenManager.reloadAllScreens() }
                )
            }

            HStack(spacing: DesignTokens.Settings.actionGridSpacing) {
                settingsActionButton(
                    title: "Welcome Tour",
                    accessibilityLabel: "Show welcome tour",
                    accessibilityHint: "Replays the initial onboarding flow",
                    systemImage: "sparkles",
                    action: {
                        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                            appDelegate.showOnboarding()
                        }
                    }
                )

                settingsActionButton(
                    title: "Reset Defaults",
                    accessibilityLabel: "Reset all settings to default",
                    accessibilityHint: "Erases all configurations and restores factory defaults",
                    systemImage: "arrow.counterclockwise",
                    tint: .red,
                    isDestructive: true,
                    action: { showingResetAlert = true }
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func settingsActionButton(
        title: LocalizedStringKey,
        accessibilityLabel: LocalizedStringKey,
        accessibilityHint: LocalizedStringKey,
        systemImage: String,
        tint: Color = .accentColor,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SettingsActionTileLabel(
                title: title,
                systemImage: systemImage,
                tint: tint,
                isDestructive: isDestructive
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(accessibilityHint))
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(version) (\(build))"
    }

    private var appLanguageSelection: Binding<AppLanguagePreference> {
        Binding(
            get: { AppLanguagePreference(rawValue: appLanguageRawValue) ?? .system },
            set: { appLanguageRawValue = $0.rawValue }
        )
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
            validationMessage = String(localized: "✅ All \(valid) configurations are valid.", comment: "Validation success message. The placeholder is the valid configuration count.")
        } else {
            validationMessage = String(localized: "Validation complete: \(valid) of \(valid + invalid) configurations are valid.\n\n", comment: "Validation summary. Placeholders are valid count and total count.")

            if disconnectedInvalid > 0 {
                validationMessage += String(localized: "• \(disconnectedInvalid) invalid configurations are for disconnected screens.\n", comment: "Validation detail. The placeholder is the invalid disconnected-screen count.")
            }

            if connectedInvalid > 0 {
                validationMessage += String(localized: "• \(connectedInvalid) invalid configurations are for connected screens.\n", comment: "Validation detail. The placeholder is the invalid connected-screen count.")
                validationMessage += String(localized: "\nYou may need to reconfigure these screens.", defaultValue: "\nYou may need to reconfigure these screens.", comment: "Validation follow-up guidance.")
            }
        }

        showingValidationResults = true
    }
}

private struct SettingsActionTileLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = .accentColor
    var isDestructive: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isDestructive ? Color.red : Color.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .strokeBorder(tint.opacity(isDestructive ? 0.35 : 0.12), lineWidth: 0.5)
        )
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
