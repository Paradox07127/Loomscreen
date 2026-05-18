import LiveWallpaperCore
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct GeneralSettingsView: View {
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRawValue = AppLanguagePreference.system.rawValue
    @State private var globalPauseOnBattery: Bool
    @State private var startOnLogin: Bool
    @State private var preservePlaybackOnLock: Bool
    @State private var minimumBatteryLevel: Double?
    @State private var useBatteryThreshold: Bool
    @State private var pauseOnFullScreen: Bool
    @State private var showInDock: Bool
    @State private var menuBarDensity: MenuBarDensity
    /// Slider value held in MB for UI ergonomics — converted to bytes when
    /// persisted to `GlobalSettings.videoCacheMaxBytesPerScreen`. `Double`
    /// because SwiftUI's `Slider` is a `Double` ramp; the step ensures it
    /// always lands on a `% 32 == 0` MB boundary so the label reads cleanly.
    @State private var videoCacheBudgetMB: Double

    @State private var pendingDestructive: PendingDestructive?

    /// Pending import bundle: shown in a confirmation alert before applying
    /// so users can back out after seeing what's inside.
    @State private var pendingImportBundle: ConfigurationBundle?
    @State private var pendingImportSource: URL?
    @State private var importFeedback: String?
    @State private var importErrorMessage: String?
    @State private var exportErrorMessage: String?

    /// Drives SwiftUI's native `.fileExporter` / `.fileImporter` sheets —
    /// these handle UTType filtering, sandbox extensions, and sheet
    /// modality automatically, which `NSSavePanel.runModal()` does not.
    @State private var isPresentingExporter = false
    @State private var isPresentingImporter = false
    @State private var exportDocument: ConfigurationDocument?

    init() {
        let settings = SettingsManager.shared.loadGlobalSettings()
        _globalPauseOnBattery = State(initialValue: settings.globalPauseOnBattery)
        _startOnLogin = State(initialValue: settings.startOnLogin)
        _preservePlaybackOnLock = State(initialValue: settings.preservePlaybackOnLock)
        _minimumBatteryLevel = State(initialValue: settings.minimumBatteryLevel)
        _useBatteryThreshold = State(initialValue: settings.minimumBatteryLevel != nil)
        _pauseOnFullScreen = State(initialValue: settings.pauseOnFullScreen)
        _showInDock = State(initialValue: settings.showInDock)
        _menuBarDensity = State(initialValue: settings.menuBarDensity)
        _videoCacheBudgetMB = State(initialValue: Double(settings.videoCacheMaxBytesPerScreen) / Double(1024 * 1024))
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            if featureCatalog.isEnabled(.globalShortcuts) {
                ShortcutsSettingsView()
                    .tabItem { Label("Shortcuts", systemImage: "command") }
            }

            if featureCatalog.isEnabled(.weatherReactive) {
                WeatherLocationSettingsView()
                    .tabItem { Label("Weather", systemImage: "cloud.sun") }
            }

            #if !LITE_BUILD
            if featureCatalog.isEnabled(.wpeImport) {
                WPECacheManagementView()
                    .tabItem { Label("Cache", systemImage: "internaldrive") }
            }
            #endif

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(DesignTokens.Colors.pageBackground)
        .confirmDestructive($pendingDestructive)
        .alert(
            "Import Configuration?",
            isPresented: Binding(
                get: { pendingImportBundle != nil },
                set: { if !$0 { pendingImportBundle = nil; pendingImportSource = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingImportBundle = nil
                pendingImportSource = nil
            }
            Button("Import", role: .destructive) { applyPendingImport() }
        } message: {
            Text(importConfirmationMessage)
        }
        .alert(
            "Configuration Imported",
            isPresented: Binding(
                get: { importFeedback != nil },
                set: { if !$0 { importFeedback = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: importFeedback ?? "")
        }
        .errorAlert("Import Failed", message: $importErrorMessage)
        .errorAlert("Export Failed", message: $exportErrorMessage)
        .fileExporter(
            isPresented: $isPresentingExporter,
            document: exportDocument,
            contentType: ConfigurationBundle.contentType,
            defaultFilename: ConfigurationPorter.suggestedExportFileName()
        ) { result in
            exportDocument = nil
            switch result {
            case .success:
                Logger.info("Configuration export completed", category: .settings)
            case .failure(let error):
                exportErrorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isPresentingImporter,
            allowedContentTypes: [ConfigurationBundle.contentType],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
    }

    // MARK: - Import / Export Action Handlers

    /// Builds the document snapshot from the current SettingsManager state and asks SwiftUI to present its native export sheet.
    private func beginExport() {
        do {
            exportDocument = try ConfigurationDocument.snapshot()
            isPresentingExporter = true
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    /// Triggers the `.fileImporter` sheet.
    private func beginImport() {
        isPresentingImporter = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let source = urls.first else { return }
            let didStartAccess = source.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    source.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let bundle = try ConfigurationPorter.decode(from: source)
                pendingImportSource = source
                pendingImportBundle = bundle
            } catch let error as ConfigurationPorter.ImportError {
                importErrorMessage = error.errorDescription
            } catch {
                importErrorMessage = error.localizedDescription
            }

        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    private func applyPendingImport() {
        guard let bundle = pendingImportBundle else { return }
        let summary = ConfigurationPorter.apply(bundle)
        pendingImportBundle = nil
        pendingImportSource = nil

        postSettingsNotificationAsync(.dockVisibilityDidChange)
        postSettingsNotificationAsync(.globalShortcutsDidChange)
        postSettingsNotificationAsync(.weatherLocationPreferenceDidChange)
        screenManager.handleGlobalSettingsChanged()
        screenManager.resetAllWallpaperSessions()
        screenManager.refreshScreens(preserveRuntimeSessions: false)

        let settings = SettingsManager.shared.loadGlobalSettings()
        globalPauseOnBattery = settings.globalPauseOnBattery
        startOnLogin = settings.startOnLogin
        preservePlaybackOnLock = settings.preservePlaybackOnLock
        minimumBatteryLevel = settings.minimumBatteryLevel
        useBatteryThreshold = settings.minimumBatteryLevel != nil
        pauseOnFullScreen = settings.pauseOnFullScreen
        showInDock = settings.showInDock
        menuBarDensity = settings.menuBarDensity

        let feedback = importFeedbackMessage(for: summary)
        DispatchQueue.main.async {
            importFeedback = feedback
        }
    }

    /// Renders the post-import summary using individual `String(localized:)` format strings so each restored section gets its own pluralization rule via xcstrings (no manual "(s)" suffixes, no concatenation).
    private func importFeedbackMessage(for summary: ConfigurationPorter.ApplySummary) -> String {
        guard !summary.isEmpty else {
            return String(
                localized: "Imported file contained no recognizable settings.",
                comment: "Toast shown after importing an empty configuration bundle."
            )
        }

        var lines: [String] = []
        if let count = summary.displayCount {
            lines.append(String(
                localized: "Restored \(count) display configurations.",
                comment: "Import success line: how many displays were restored. xcstrings provides a pluralized variant."
            ))
        }
        if summary.didRestoreGlobalSettings {
            lines.append(String(
                localized: "Restored global preferences, schedule, and shortcuts.",
                comment: "Import success line: global settings were restored."
            ))
        }
        if let count = summary.bookmarkCount {
            lines.append(String(
                localized: "Restored \(count) saved bookmarks.",
                comment: "Import success line: how many bookmarks were restored. xcstrings provides a pluralized variant."
            ))
        }
        return lines.joined(separator: "\n")
    }

    private var importConfirmationMessage: String {
        guard let bundle = pendingImportBundle else { return "" }
        var lines: [String] = []
        if let count = bundle.screenConfigurations?.count {
            lines.append(String(
                localized: "• \(count) display configurations",
                comment: "Import confirmation bullet: how many displays the bundle includes. xcstrings provides a pluralized variant."
            ))
        }
        if bundle.globalSettings != nil {
            lines.append(String(
                localized: "• Global settings (preferences, schedule, shortcuts)",
                comment: "Import confirmation bullet: presence of global settings."
            ))
        }
        if let count = bundle.wallpaperBookmarks?.count {
            lines.append(String(
                localized: "• \(count) saved bookmarks",
                comment: "Import confirmation bullet: how many bookmarks the bundle includes. xcstrings provides a pluralized variant."
            ))
        }

        let summary = lines.isEmpty
            ? String(
                localized: "The file contains no recognizable settings.",
                comment: "Import confirmation when bundle is empty."
            )
            : lines.joined(separator: "\n")

        return String(
            localized: "\(summary)\n\n\(localizedBookmarkPortabilityWarning)\n\nReplace current configuration?",
            comment: "Import confirmation alert message. First placeholder is a bulleted list of restored sections; second is the device-portability warning."
        )
    }

    private var localizedBookmarkPortabilityWarning: String {
        String(
            localized: "Selected files and folders will need to be re-granted on this Mac because security bookmarks are device-specific.",
            comment: "Import confirmation footer warning about cross-device bookmark portability."
        )
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalTab: some View {
        settingsForm {
            Section {
                SettingRow(icon: "globe", iconColor: .teal, title: "Language", subtitle: "Choose the display language used by LiveWallpaper") {
                    languagePicker
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

                SettingRow(icon: "menubar.rectangle", iconColor: .teal, title: "Menu bar density", subtitle: "Compact tightens padding so more displays fit without scrolling") {
                    Picker("", selection: $menuBarDensity) {
                        ForEach(MenuBarDensity.allCases) { density in
                            Text(LocalizedStringKey(density.titleKey)).tag(density)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .onChange(of: menuBarDensity) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Menu bar density"))
                }
            } header: {
                Text("Behavior")
            }

            performanceSection

            powerSavingSection

            batteryThresholdSection

            Section {
                troubleshootingActions
            } header: {
                Text("Troubleshooting")
            }
        }
    }

    // MARK: - General Sections

    /// Per-screen RAM budget for the in-memory video cache. Driving the
    /// budget from a slider rather than a 3-mode picker lets each user dial
    /// in their own RAM-vs-disk-reads trade-off instead of taking whichever
    /// preset we picked.
    ///
    /// 0 = streaming only (no caching). The "total" line under the slider
    /// makes the multi-screen multiplier explicit so users see the full
    /// memory implication before letting go of the thumb.
    @ViewBuilder
    private var performanceSection: some View {
        Section {
            SettingRow(
                icon: "memorychip",
                iconColor: .pink,
                title: "Video memory cache",
                subtitle: cacheSubtitleKey
            ) {
                EmptyView()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(videoCacheValueLabel)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(videoCacheTotalLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { videoCacheBudgetMB },
                        set: { newValue in
                            let snapped = (newValue / 32).rounded() * 32
                            videoCacheBudgetMB = snapped
                            updateGlobalSettings()
                        }
                    ),
                    in: 0...Double(GlobalSettings.maxVideoCacheBytes / (1024 * 1024)),
                    step: 32
                ) {
                    Text("Video memory cache")
                } minimumValueLabel: {
                    Text("0")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("1 GB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text("Video memory cache per screen"))
                .accessibilityValue(Text(videoCacheValueLabel))
            }
            .padding(.vertical, 4)
        } header: {
            Text("Performance")
        }
    }

    private var videoCacheValueLabel: String {
        if videoCacheBudgetMB <= 0 {
            return "Streaming only"
        }
        return "\(Int(videoCacheBudgetMB)) MB / screen"
    }

    private var videoCacheTotalLabel: String {
        let screenCount = max(screenManager.screens.count, 1)
        if videoCacheBudgetMB <= 0 {
            return "\(screenCount) screen\(screenCount == 1 ? "" : "s") — 0 MB cached"
        }
        let totalMB = Int(videoCacheBudgetMB) * screenCount
        return "\(screenCount) screen\(screenCount == 1 ? "" : "s") — up to \(totalMB) MB total"
    }

    private var cacheSubtitleKey: LocalizedStringKey {
        "Higher = fewer disk reads, more RAM. Lower = less RAM, video re-reads disk on every loop."
    }

    @ViewBuilder
    private var powerSavingSection: some View {
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
    }

    @ViewBuilder
    private var batteryThresholdSection: some View {
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
        .background(DesignTokens.Colors.pageBackground)
    }

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .settingsFormChrome()
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

    private var troubleshootingActions: some View {
        Grid(horizontalSpacing: DesignTokens.Settings.actionGridSpacing,
             verticalSpacing: DesignTokens.Settings.actionGridSpacing) {
            GridRow {
                settingsActionButton(
                    title: "Export",
                    accessibilityLabel: "Export configuration",
                    accessibilityHint: "Save the current settings, bookmarks, and per-display setup to a backup file",
                    systemImage: "square.and.arrow.up",
                    action: beginExport
                )

                settingsActionButton(
                    title: "Import",
                    accessibilityLabel: "Import configuration",
                    accessibilityHint: "Restore settings, bookmarks, and per-display setup from a backup file",
                    systemImage: "square.and.arrow.down",
                    action: beginImport
                )
            }

            GridRow {
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
                    action: {
                        pendingDestructive = PendingDestructive(.resetAllSettings) {
                            resetAllSettings()
                        }
                    }
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
        var settings = SettingsManager.shared.loadGlobalSettings()
        let dockChanged = settings.showInDock != showInDock
        let densityChanged = settings.menuBarDensity != menuBarDensity
        settings.globalPauseOnBattery = globalPauseOnBattery
        settings.preservePlaybackOnLock = preservePlaybackOnLock
        settings.startOnLogin = startOnLogin
        settings.minimumBatteryLevel = useBatteryThreshold ? minimumBatteryLevel : nil
        settings.pauseOnFullScreen = pauseOnFullScreen
        settings.showInDock = showInDock
        settings.menuBarDensity = menuBarDensity
        settings.videoCacheMaxBytesPerScreen = Int(videoCacheBudgetMB) * 1024 * 1024
        SettingsManager.shared.saveGlobalSettings(settings)
        screenManager.handleGlobalSettingsChanged()
        if dockChanged {
            postSettingsNotificationAsync(.dockVisibilityDidChange)
        }
        if densityChanged {
            postSettingsNotificationAsync(.menuBarDensityDidChange)
        }
    }

    /// Defers the post to the next MainActor turn so it does not fire inside
    /// the SwiftUI reconcile pass that triggered the save (CLAUDE.md §3).
    private func postSettingsNotificationAsync(_ name: Notification.Name) {
        Task { @MainActor in
            NotificationCenter.default.post(name: name, object: nil)
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
        menuBarDensity = .comfortable

        postSettingsNotificationAsync(.dockVisibilityDidChange)
        postSettingsNotificationAsync(.globalShortcutsDidChange)
        postSettingsNotificationAsync(.weatherLocationPreferenceDidChange)
        screenManager.handleGlobalSettingsChanged()
        screenManager.resetAllWallpaperSessions()
        screenManager.refreshScreens(preserveRuntimeSessions: false)
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
