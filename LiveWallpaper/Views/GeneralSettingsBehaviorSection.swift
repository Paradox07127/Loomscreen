import LiveWallpaperCore
import ServiceManagement
import SwiftUI

extension GeneralSettingsView {
    @ViewBuilder
    var behaviorSection: some View {
        Section {
            SettingRow(icon: "globe", iconColor: .teal, title: "Language", subtitle: "Choose the display language used by LiveWallpaper") {
                languagePicker
            }

            SettingRow(
                icon: "power.circle.fill",
                iconColor: loginItemShowsInlineStatus ? loginItemStatusColor : .green,
                title: "Start at login",
                subtitle: "Automatically launch LiveWallpaper when you log in"
            ) {
                HStack(spacing: 8) {
                    if loginItemShowsInlineStatus {
                        GeneralSettingsStatusPill(text: loginItemStatusText, color: loginItemStatusColor)
                            .help(Text(verbatim: loginItemStatusSubtitle))
                    }

                    if loginItemNeedsApproval {
                        Button("Open") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel(Text("Open Login Items settings"))
                    }

                    Toggle("", isOn: $startOnLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: startOnLogin) { _, _ in
                            updateGlobalSettings()
                            scheduleSystemStatusRefresh(.loginItem)
                        }
                        .accessibilityLabel(Text("Start at login"))
                        .accessibilityHint(Text("Automatically launch LiveWallpaper when you log in"))
                }
            }

            SettingRow(
                icon: "lock.display",
                iconColor: .blue,
                title: "Preserve wallpaper on the lock screen",
                subtitle: "Show your wallpaper's last frame when locked, instead of the default picture",
                info: "On lock, the current wallpaper frame is captured as the macOS desktop picture so the lock screen keeps your wallpaper's look. Only affects displays that already have a Desktop Picture set."
            ) {
                Toggle("", isOn: $preservePlaybackOnLock)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: preservePlaybackOnLock) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Preserve wallpaper on the lock screen"))
                    .accessibilityHint(Text("Shows your wallpaper's last frame on the lock screen instead of the default picture"))
            }

            SettingRow(
                icon: "dock.rectangle",
                iconColor: .indigo,
                title: "Show in Dock",
                subtitle: "Make the app visible in the Dock and Cmd-Tab switcher",
                info: "When off, the app keeps running in the background — reopen this window anytime from the menu bar icon at the top-right of your screen."
            ) {
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
    }

    private var languagePicker: some View {
        Picker("", selection: appLanguageSelection) {
            ForEach(AppLanguagePreference.allCases) { language in
                Text(language.titleKey).tag(language)
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(Text("Language"))
        .accessibilityHint(Text("Choose the display language used by LiveWallpaper"))
    }

    private var appLanguageSelection: Binding<AppLanguagePreference> {
        Binding(
            get: { AppLanguagePreference(rawValue: appLanguageRawValue) ?? .system },
            set: { appLanguageRawValue = $0.rawValue }
        )
    }

    // MARK: - Login Item Inline Status

    private var loginItemNeedsApproval: Bool {
        startOnLogin && !loginItemStatusRefreshPending && loginItemStatus == .requiresApproval
    }

    private var loginItemShowsInlineStatus: Bool {
        startOnLogin || loginItemNeedsApproval || loginItemStatusRefreshPending
    }

    private var loginItemStatusText: String {
        if loginItemStatusRefreshPending {
            return "Checking…"
        }
        switch loginItemStatus {
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Needs Approval"
        case .notRegistered:
            return startOnLogin ? "Not Granted" : "Off"
        case .notFound:
            return "Unavailable"
        @unknown default:
            return "Unknown"
        }
    }

    private var loginItemStatusSubtitle: String {
        if loginItemStatusRefreshPending {
            return "Waiting for macOS to update Login Items status"
        }
        switch loginItemStatus {
        case .enabled:
            return "Launch at login is enabled"
        case .requiresApproval:
            return "Approve LiveWallpaper in Login Items"
        case .notRegistered:
            return startOnLogin ? "Registration is pending or blocked" : "Launch at login is off"
        case .notFound:
            return "macOS could not find the app service"
        @unknown default:
            return "macOS returned an unknown login item status"
        }
    }

    private var loginItemStatusColor: Color {
        if loginItemStatusRefreshPending {
            return .secondary
        }
        switch loginItemStatus {
        case .enabled:
            return DesignTokens.Colors.Status.active
        case .requiresApproval:
            return DesignTokens.Colors.Status.warning
        case .notRegistered:
            return startOnLogin ? DesignTokens.Colors.Status.warning : .secondary
        case .notFound:
            return DesignTokens.Colors.Status.danger
        @unknown default:
            return .secondary
        }
    }
}
