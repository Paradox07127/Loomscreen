import LiveWallpaperCore
import ServiceManagement
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
    @State private var pauseOnFullScreen: Bool
    @State private var pauseInGameMode: Bool
    @State private var pauseOnWindowOcclusion: Bool
    @State private var applicationRules: [ApplicationPerformanceRule]
    @State private var showAppExceptions = false
    @State private var showInDock: Bool
    /// Slider value held in MB for UI ergonomics — converted to bytes when
    /// persisted to `GlobalSettings.videoCacheMaxBytesPerScreen`. `Double`
    /// because SwiftUI's `Slider` is a `Double` ramp; the step ensures it
    /// always lands on a `% 32 == 0` MB boundary so the label reads cleanly.
    @State private var videoCacheBudgetMB: Double
    /// Pro-only runtime opt-in for the Developer Tools sidebar entry and
    /// `WKWebView.isInspectable` on HTML wallpapers. Hidden in Lite via
    /// `#if !LITE_BUILD` + capability gate so the row never renders.
    @State private var developerModeEnabled: Bool

    /// Pro-only master switch for audio-reactive wallpapers (system-audio
    /// loopback capture). Default off — privacy-sensitive opt-in.
    @State private var audioResponseEnabled: Bool
    /// Weather-reactive location source + manual city. Lives on General
    /// (rather than a dedicated tab) because the surface is tiny and
    /// only relevant to users who run weather-reactive particle effects.
    @State private var weatherLocation: WeatherLocationPreference

    @State private var pendingDestructive: PendingDestructive?
    @State private var pendingBugReport: BugReport?

    @State private var loginItemAlert: LoginItemFailure?

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
        _pauseOnFullScreen = State(initialValue: settings.pauseOnFullScreen)
        _pauseInGameMode = State(initialValue: settings.pauseInGameMode)
        _pauseOnWindowOcclusion = State(initialValue: settings.pauseOnWindowOcclusion)
        _applicationRules = State(initialValue: settings.applicationPerformanceRules)
        _showInDock = State(initialValue: settings.showInDock)
        _videoCacheBudgetMB = State(initialValue: Double(settings.videoCacheMaxBytesPerScreen) / Double(1024 * 1024))
        _developerModeEnabled = State(initialValue: settings.developerModeEnabled)
        _audioResponseEnabled = State(initialValue: settings.audioResponseEnabled)
        _weatherLocation = State(initialValue: settings.weatherLocation)
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "command") }

            #if !LITE_BUILD && DIRECT_DISTRIBUTION
            if featureCatalog.isEnabled(.workshopOnline) {
                WorkshopSettingsView()
                    .tabItem { Label("Workshop", systemImage: "cube.transparent") }
            }
            #endif

            #if !LITE_BUILD
            if featureCatalog.isEnabled(.wpeImport) {
                WPECacheManagementView()
                    .tabItem { Label("Cache", systemImage: "internaldrive") }
            }
            #endif

            backupTab
                .tabItem { Label("Backup", systemImage: "externaldrive") }

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
        .alert(
            "Login Item",
            isPresented: Binding(
                get: { loginItemAlert != nil },
                set: { if !$0 { loginItemAlert = nil } }
            )
        ) {
            if case .requiresApproval = loginItemAlert {
                Button("Open System Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                    loginItemAlert = nil
                }
                Button("OK", role: .cancel) { loginItemAlert = nil }
            } else {
                Button("OK", role: .cancel) { loginItemAlert = nil }
            }
        } message: {
            Text(verbatim: loginItemAlert?.userFacingMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .loginItemRegistrationDidFail)) { note in
            if let reason = note.userInfo?["reason"] as? LoginItemFailure {
                loginItemAlert = reason
                // 失败时把 toggle 复位，避免 UI 显示已开但实际没生效。
                if startOnLogin {
                    startOnLogin = false
                }
            }
        }
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
        .sheet(item: $pendingBugReport) { report in
            ReportBugSheet(report: report) {
                pendingBugReport = nil
            }
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
        pauseOnFullScreen = settings.pauseOnFullScreen
        pauseInGameMode = settings.pauseInGameMode
        pauseOnWindowOcclusion = settings.pauseOnWindowOcclusion
        applicationRules = settings.applicationPerformanceRules
        showInDock = settings.showInDock
        developerModeEnabled = settings.developerModeEnabled
        audioResponseEnabled = settings.audioResponseEnabled
        weatherLocation = settings.weatherLocation
        postSettingsNotificationAsync(.developerModeDidChange)

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

            performanceSection

            audioResponseSection

            weatherSection

            advancedSection

            // Standalone Reset button — placed loose in the Form so the
            // grouped Section background doesn't render around it. The
            // destructive label + alert confirmation already carry the
            // "this is permanent" weight without needing a card frame.
            resetDefaultsRow
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        // Presented from the Performance → App Exceptions row. Attached to the
        // Form (not the Section) because `.sheet` on a `Section` inside a Form
        // doesn't reliably present on macOS — that's why "Edit…" appeared to do
        // nothing before.
        .sheet(isPresented: $showAppExceptions) {
            AppExceptionsSheet(rules: $applicationRules, onChange: updateGlobalSettings)
        }
    }

    /// Pro-only opt-in surface for diagnostic features. Compiled out of Lite
    /// (`#if !LITE_BUILD`) and only rendered when the runtime capability is
    /// also present so accidental enabling in a misconfigured SKU is
    /// impossible.
    @ViewBuilder
    private var advancedSection: some View {
        #if !LITE_BUILD
        if featureCatalog.isEnabled(.developerTools) {
            Section {
                SettingRow(
                    icon: "wrench.and.screwdriver",
                    iconColor: .orange,
                    title: "Developer Mode",
                    subtitle: "Show Developer Tools in the sidebar and enable right-click Inspect Element on HTML wallpapers.",
                    info: "When on, HTML wallpapers open with WebKit's Web Inspector accessible — right-click in a webview wallpaper to inspect. Recommended only when debugging your own content."
                ) {
                    Toggle("", isOn: $developerModeEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: developerModeEnabled) { _, _ in updateGlobalSettings() }
                        .accessibilityLabel(Text("Developer Mode"))
                        .accessibilityHint(Text("Reveals diagnostic tools and HTML web inspector. Off by default."))
                }

                if developerModeEnabled {
                    SettingRow(
                        icon: "doc.text.magnifyingglass",
                        iconColor: .orange,
                        title: "Log Files",
                        subtitle: "Open the folder containing the app's diagnostic logs."
                    ) {
                        Button("Show in Finder") { revealLogFolder() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                            .accessibilityLabel(Text("Show logs in Finder"))
                            .accessibilityHint(Text("Opens the folder containing the app's log files"))
                    }
                }
            } header: {
                Text("Advanced", comment: "Section header for Developer Mode toggle in General settings.")
            }
        }
        #endif
    }

    /// Pro-only master switch for audio-reactive wallpapers. Flipping it drives
    /// the shared `SystemAudioCaptureManager` directly so the tap starts/stops
    /// live, and persists `audioResponseEnabled` for the next launch.
    @ViewBuilder
    private var audioResponseSection: some View {
        #if !LITE_BUILD
        Section {
            SettingRow(
                icon: "waveform",
                iconColor: .pink,
                title: "Audio Response",
                subtitle: "Let audio-reactive wallpapers move with the music and sound playing on your Mac.",
                info: "Analyzes your Mac's audio output on-device to compute a frequency spectrum for audio-reactive scenes. Nothing is recorded, saved, or sent anywhere. macOS asks for permission the first time you turn this on."
            ) {
                Toggle("", isOn: $audioResponseEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: audioResponseEnabled) { _, newValue in
                        updateGlobalSettings()
                        SystemAudioCaptureManager.shared.setEnabled(newValue)
                    }
                    .accessibilityLabel(Text("Audio Response"))
                    .accessibilityHint(Text("Lets wallpapers react to the audio playing on your Mac. Off by default; requires audio-recording permission."))
            }
        } header: {
            Text("Audio", comment: "Section header for the audio-response toggle in General settings.")
        }
        #endif
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
            SettingRow(icon: "macwindow.badge.plus", iconColor: .purple, title: "Pause on full-screen apps", subtitle: "Automatically pause wallpapers when a full-screen app is active") {
                Toggle("", isOn: $pauseOnFullScreen)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: pauseOnFullScreen) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause on full-screen apps"))
                    .accessibilityHint(Text("Automatically pause wallpapers when a full-screen app is active"))
            }

            SettingRow(icon: "rectangle.on.rectangle", iconColor: .purple, title: "Pause when windows cover the desktop", subtitle: "Also pause when other apps' windows blanket at least 85% of a display, even if none is full-screen") {
                Toggle("", isOn: $pauseOnWindowOcclusion)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: pauseOnWindowOcclusion) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause when windows cover the desktop"))
                    .accessibilityHint(Text("Pause when other apps' windows cover at least 85 percent of a display"))
            }

            SettingRow(icon: "gamecontroller", iconColor: .green, title: "Pause when a game is active", subtitle: "Yield the GPU when the frontmost app is a game, or macOS enters Low Power Mode") {
                Toggle("", isOn: $pauseInGameMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: pauseInGameMode) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause when a game is active"))
                    .accessibilityHint(Text("Yield the GPU when the frontmost app is a game, or macOS enters Low Power Mode"))
            }

            SettingRow(icon: "bolt.circle.fill", iconColor: .yellow, title: "Pause on battery", subtitle: "Switch wallpapers to a static frame when your Mac is unplugged") {
                Toggle("", isOn: $globalPauseOnBattery)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: globalPauseOnBattery) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause on battery"))
                    .accessibilityHint(Text("Switch wallpapers to a static frame when your Mac is unplugged"))
            }

            SettingRow(
                icon: "hand.raised",
                iconColor: .blue,
                title: "App Exceptions",
                subtitle: applicationRules.isEmpty
                    ? "Pause wallpapers while chosen apps are in use"
                    : "Active for \(applicationRules.count) app\(applicationRules.count == 1 ? "" : "s")"
            ) {
                Button("Edit…") { showAppExceptions = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    // Without fixedSize the SettingRow's flexible title column
                    // (maxWidth: .infinity, layoutPriority 1) starves the button
                    // of width and clips its label to an empty border — pin it to
                    // its intrinsic size like the Backup-tab buttons.
                    .fixedSize()
                    .accessibilityLabel(Text("Edit application exceptions"))
            }

            SettingRow(
                icon: "memorychip",
                iconColor: .pink,
                title: "Video memory cache",
                subtitle: "Per-screen RAM budget",
                info: "Higher = fewer disk reads, more RAM. Lower = less RAM, video re-reads disk on every loop."
            ) {
                // Slider sits in the SettingRow's trailing slot so the
                // header, the affordance, and the current value all read as
                // a single row group — matching the way macOS System
                // Settings inlines a slider next to its labeled title.
                // The value text stays right-aligned directly under the
                // slider to keep the rightmost edge visually anchored.
                VStack(alignment: .trailing, spacing: 4) {
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
                        Text("Off")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("1 GB")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 240)
                    .accessibilityLabel(Text("Video memory cache per screen"))
                    .accessibilityValue(Text(videoCacheValueLabel))

                    Text(videoCacheValueLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Performance & Battery")
        }
    }

    /// Compact one-line representation of the current cache budget, in the
    /// form `150 MB · 300 MB total` (per-screen · total across all screens).
    /// Off-state collapses to a single `"Streaming only"` token so we never
    /// surface a misleading "0 MB total" when the user disabled caching.
    private var videoCacheValueLabel: String {
        guard videoCacheBudgetMB > 0 else { return "Streaming only" }

        let perScreenMB = Int(videoCacheBudgetMB)
        let screenCount = max(screenManager.screens.count, 1)
        if screenCount == 1 {
            return "\(perScreenMB) MB"
        }
        let totalMB = perScreenMB * screenCount
        return "\(perScreenMB) MB · \(totalMB) MB total"
    }

    /// Weather-reactive location source. Inlined here so the user does
    /// not need to hunt across tabs for a tiny picker. Persists straight
    /// into `GlobalSettings.weatherLocation` and broadcasts the change
    /// notification through the same coordinator path used by every
    /// other GlobalSettings field.
    @ViewBuilder
    private var weatherSection: some View {
        Section {
            VStack(spacing: 8) {
                // Centered fixed-size pill matches macOS System Settings'
                // top-of-section segmented controls (e.g. Display arrangement
                // mode), reading as a "choose your input" hero rather than a
                // dense form row.
                Picker("Source", selection: weatherSourceBinding) {
                    Text("Off").tag(WeatherLocationPreference.Source.off)
                    Text("System").tag(WeatherLocationPreference.Source.coreLocation)
                    Text("Manual").tag(WeatherLocationPreference.Source.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(Text("Weather location source"))

                if weatherLocation.source == .manual {
                    ManualLocationPicker(
                        currentSelection: weatherLocation.manual,
                        onCommit: { manual in
                            weatherLocation.manual = manual
                            persistWeatherLocation()
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
        } header: {
            Text("Weather")
        } footer: {
            Text("Used by weather-reactive effects like rain, snow, and fog.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var weatherSourceBinding: Binding<WeatherLocationPreference.Source> {
        Binding(
            get: { weatherLocation.source },
            set: { newValue in
                guard weatherLocation.source != newValue else { return }
                weatherLocation.source = newValue
                persistWeatherLocation()
            }
        )
    }

    private func persistWeatherLocation() {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.weatherLocation = weatherLocation
        SettingsManager.shared.saveGlobalSettings(settings)
        postSettingsNotificationAsync(.weatherLocationPreferenceDidChange)
    }

    // MARK: - About Tab

    @ViewBuilder
    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 28) {
                aboutHero
                #if LITE_BUILD
                UpdateBannerView()
                #endif
                aboutTagline
                aboutActionGrid
                aboutFooter
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.pageBackground)
    }

    private var aboutHero: some View {
        VStack(spacing: 14) {
            ZStack {
                // Soft accent halo behind the icon — gives the hero presence
                // without the AI-slop "drop shadow on a flat icon" look.
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 128, height: 128)
                    .blur(radius: 18)

                Image(systemName: "play.rectangle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(verbatim: BundleIdentity.productDisplayName)
                    .font(.system(size: 24, weight: .semibold))
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Text(verbatim: versionString)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(versionString, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(Text("Copy version to clipboard"))
                    .accessibilityLabel(Text("Copy version"))
                }
            }
        }
    }

    private var aboutTagline: some View {
        Text("Live wallpapers for macOS: videos, web pages, and compatible imported scenes across every connected display.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
    }

    private var aboutActionGrid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                aboutTile(
                    title: "View on GitHub",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    accent: .blue,
                    url: URL(string: "https://github.com/Paradox07127/Loomscreen")
                )
                aboutTile(
                    title: "Discussions",
                    systemImage: "bubble.left.and.bubble.right",
                    accent: .indigo,
                    url: URL(string: "https://github.com/Paradox07127/Loomscreen/discussions")
                )
            }
            GridRow {
                aboutTile(
                    title: "Report a Bug",
                    systemImage: "ladybug",
                    accent: .red,
                    action: presentBugReport
                )
                aboutTile(
                    title: "Welcome Tour",
                    systemImage: "sparkles",
                    accent: .purple,
                    action: {
                        // `NSApplication.shared.delegate` is `SwiftUI.AppDelegate`
                        // (an internal wrapper around `@NSApplicationDelegateAdaptor`),
                        // so casting to our own `AppDelegate` fails. Route the
                        // request via NotificationCenter instead — AppDelegate
                        // observes `.showOnboarding` and triggers the window.
                        NotificationCenter.default.post(name: .showOnboarding, object: nil)
                    }
                )
            }
        }
        .frame(maxWidth: 360)
    }

    /// Tile-style call-to-action. Uses a low-key surface so the four CTAs read
    /// as a related group rather than four shouting buttons. Apple's About
    /// pages keep this region quiet; the hero block does the talking.
    @ViewBuilder
    private func aboutTile(
        title: LocalizedStringKey,
        systemImage: String,
        accent: Color,
        url: URL? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            if let action {
                action()
            } else if let url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(accent)
                    .frame(height: 26)

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(action == nil && url == nil)
    }

    /// Author / copyright / license at the very bottom — small, restrained,
    /// selectable. Placeholders need to be replaced before shipping.
    private var aboutFooter: some View {
        VStack(spacing: 4) {
            Text("Made by Paradox07127")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(verbatim: "© 2026 Loomscreen contributors · MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .padding(.top, 4)
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

    private var resetDefaultsRow: some View {
        HStack {
            Spacer()
            Button {
                pendingDestructive = PendingDestructive(.resetAllSettings) {
                    resetAllSettings()
                }
            } label: {
                Label("Reset Defaults", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.regular)
            .accessibilityLabel(Text("Reset all settings to default"))
            .accessibilityHint(Text("Erases all configurations and restores factory defaults"))
            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - Backup Tab

    @ViewBuilder
    private var backupTab: some View {
        settingsForm {
            Section {
                SettingRow(
                    icon: "square.and.arrow.up",
                    iconColor: .blue,
                    title: "Export Configuration",
                    subtitle: "Save settings, bookmarks, and per-display setup to a .lwconfig file",
                    info: "The bundle includes all global preferences, the wallpaper library bookmarks, and the per-display playback / effect setup. Wallpaper files themselves are not copied — only references to them."
                ) {
                    Button("Export…") { beginExport() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityHint(Text("Save the current settings, bookmarks, and per-display setup to a backup file"))
                }

                SettingRow(
                    icon: "square.and.arrow.down",
                    iconColor: .blue,
                    title: "Import Configuration",
                    subtitle: "Restore from a previously exported .lwconfig file",
                    info: "Importing replaces the current global preferences and per-display setup. Bookmarks from the backup are merged into your library — existing entries with the same source are kept."
                ) {
                    Button("Import…") { beginImport() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityHint(Text("Restore settings, bookmarks, and per-display setup from a backup file"))
                }
            } header: {
                Text("Backup & Restore")
            } footer: {
                Text("Backup files travel between Macs and let you roll back a misconfiguration. They contain bookmarks (pointers to your wallpaper files) but not the wallpaper files themselves — the original folders must exist on the destination Mac for the bookmarks to resolve.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func presentBugReport() {
        let kinds: [String] = screenManager.wallpaperSessionSummaries
            .compactMap { $0.wallpaperType?.rawValue }
        pendingBugReport = BugReporter.makeReport(activeWallpaperKinds: kinds)
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
        let developerModeChanged = settings.developerModeEnabled != developerModeEnabled
        settings.globalPauseOnBattery = globalPauseOnBattery
        settings.preservePlaybackOnLock = preservePlaybackOnLock
        settings.startOnLogin = startOnLogin
        settings.pauseOnFullScreen = pauseOnFullScreen
        settings.pauseInGameMode = pauseInGameMode
        settings.pauseOnWindowOcclusion = pauseOnWindowOcclusion
        settings.applicationPerformanceRules = applicationRules
        settings.showInDock = showInDock
        settings.videoCacheMaxBytesPerScreen = Int(videoCacheBudgetMB) * 1024 * 1024
        settings.developerModeEnabled = developerModeEnabled
        settings.audioResponseEnabled = audioResponseEnabled
        SettingsManager.shared.saveGlobalSettings(settings)
        screenManager.handleGlobalSettingsChanged()
        if dockChanged {
            postSettingsNotificationAsync(.dockVisibilityDidChange)
        }
        if developerModeChanged {
            postSettingsNotificationAsync(.developerModeDidChange)
        }
    }

    /// Defers the post to the next MainActor turn so it does not fire inside
    /// the SwiftUI reconcile pass that triggered the save (CLAUDE.md §3).
    private func postSettingsNotificationAsync(_ name: Notification.Name) {
        Task { @MainActor in
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    private func revealLogFolder() {
        if let logURL = Logger.persistentLogFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
            return
        }
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/LiveWallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private func resetAllSettings() {
        SettingsManager.shared.cleanAllSettings()

        globalPauseOnBattery = false
        startOnLogin = false
        preservePlaybackOnLock = false
        pauseOnFullScreen = true
        pauseInGameMode = true
        pauseOnWindowOcclusion = false
        applicationRules = []
        showInDock = false
        developerModeEnabled = false
        weatherLocation = .default

        postSettingsNotificationAsync(.dockVisibilityDidChange)
        postSettingsNotificationAsync(.globalShortcutsDidChange)
        postSettingsNotificationAsync(.weatherLocationPreferenceDidChange)
        postSettingsNotificationAsync(.developerModeDidChange)
        screenManager.handleGlobalSettingsChanged()
        screenManager.resetAllWallpaperSessions()
        screenManager.refreshScreens(preserveRuntimeSessions: false)
    }

}
