import LiveWallpaperCore
import ServiceManagement
import SwiftUI
import AppKit
import CoreLocation
import UniformTypeIdentifiers

enum GeneralSettingsPage {
    case general
    case performancePower
    case audioResponse
    case weather
    case backupRestore
    case advanced
    case about
}

private enum SystemStatusScope {
    case loginItem
    case audioCapture
    case weatherLocation
}

struct GeneralSettingsView: View {
    @Environment(ScreenManager.self) private var screenManager
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRawValue = AppLanguagePreference.system.rawValue
    @State private var globalPauseOnBattery: Bool
    @State private var startOnLogin: Bool
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemStatusRefreshPending = false
    @State private var loginItemStatusRefreshGeneration = 0
    @State private var preservePlaybackOnLock: Bool
    @State private var pauseOnFullScreen: Bool
    @State private var pauseInGameMode: Bool
    @State private var pauseOnWindowOcclusion: Bool
    @State private var applicationRules: [ApplicationPerformanceRule]
    @State private var showAppExceptions = false
    @State private var showInDock: Bool
    /// In MB (converted to bytes on persist). `Double` for SwiftUI `Slider`;
    /// the step snaps to a `% 32 == 0` MB boundary so the label reads cleanly.
    @State private var videoCacheBudgetMB: Double
    /// Hidden in Lite via `#if !LITE_BUILD` + capability gate so the row never renders.
    @State private var developerModeEnabled: Bool

    /// Default off — privacy-sensitive opt-in.
    @State private var audioResponseEnabled: Bool
    #if !LITE_BUILD
    @State private var audioCaptureState = SystemAudioCaptureManager.shared.state
    @State private var audioStatusRefreshPending = false
    @State private var audioStatusRefreshGeneration = 0
    #endif
    /// Default off — Pro-only scene power saving (adaptive frame rate).
    @State private var adaptiveFrameRateEnabled: Bool
    @State private var weatherLocation: WeatherLocationPreference
    @State private var locationAuthorizationStatus = CLLocationManager().authorizationStatus
    @State private var weatherStatusRefreshPending = false
    @State private var weatherStatusRefreshGeneration = 0

    @State private var pendingBugReport: BugReport?

    @State private var loginItemAlert: LoginItemFailure?

    /// Held so the user confirms in an alert before the import is applied (staged confirm-then-apply).
    @State private var pendingImportBundle: ConfigurationBundle?
    @State private var pendingImportSource: URL?
    @State private var importFeedback: String?
    @State private var importErrorMessage: String?
    @State private var exportErrorMessage: String?
    @State private var diagnosticsExportErrorMessage: String?

    /// Drives SwiftUI's native `.fileExporter` / `.fileImporter` sheets —
    /// these handle UTType filtering, sandbox extensions, and sheet
    /// modality automatically, which `NSSavePanel.runModal()` does not.
    @State private var isPresentingExporter = false
    @State private var isPresentingImporter = false
    @State private var isPresentingDiagnosticsExporter = false
    @State private var exportDocument: ConfigurationDocument?
    @State private var diagnosticsDocument: DiagnosticDocument?

    private let page: GeneralSettingsPage

    init(page: GeneralSettingsPage = .general) {
        self.page = page
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
        _adaptiveFrameRateEnabled = State(initialValue: settings.adaptiveFrameRateEnabled)
        _weatherLocation = State(initialValue: settings.weatherLocation)
    }

    var body: some View {
        contentForPage
        .frame(minWidth: 500, minHeight: 400)
        .background(DesignTokens.Colors.pageBackground)
        .onAppear { refreshSystemStatusIndicators() }
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
        .errorAlert("Diagnostics Export Failed", message: $diagnosticsExportErrorMessage)
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
                loginItemStatusRefreshPending = false
                loginItemStatus = SMAppService.mainApp.status
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
        .fileExporter(
            isPresented: $isPresentingDiagnosticsExporter,
            document: diagnosticsDocument,
            contentType: .plainText,
            defaultFilename: "LiveWallpaper Diagnostics.txt"
        ) { result in
            diagnosticsDocument = nil
            switch result {
            case .success:
                Logger.info("Diagnostics export completed", category: .settings)
            case .failure(let error):
                diagnosticsExportErrorMessage = error.localizedDescription
            }
        }
        .sheet(item: $pendingBugReport) { report in
            ReportBugSheet(report: report) {
                pendingBugReport = nil
            }
        }
        .sheet(isPresented: $showAppExceptions) {
            AppExceptionsSheet(rules: $applicationRules, onChange: updateGlobalSettings)
        }
    }

    // MARK: - Import / Export Action Handlers

    private func beginExport() {
        do {
            exportDocument = try ConfigurationDocument.snapshot()
            isPresentingExporter = true
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

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

    /// Individual `String(localized:)` per section so each gets its own xcstrings pluralization rule (no manual "(s)", no concatenation).
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
                localized: "Restored global preferences, display defaults, schedule, and shortcuts.",
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
                localized: "• Global settings (preferences, display defaults, schedule, shortcuts)",
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

    // MARK: - Settings Pages

    @ViewBuilder
    private var contentForPage: some View {
        switch page {
        case .general:
            settingsForm {
                behaviorSection
            }
        case .performancePower:
            settingsForm {
                performanceSection
            }
        case .audioResponse:
            settingsForm {
                audioResponseSection
            }
        case .weather:
            settingsForm {
                weatherSection
            }
        case .backupRestore:
            settingsForm {
                backupSection
            }
        case .advanced:
            settingsForm {
                advancedSection
            }
        case .about:
            aboutTab
        }
    }

    @ViewBuilder
    private var behaviorSection: some View {
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
                        SettingsStatusPill(text: loginItemStatusText, color: loginItemStatusColor)
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

    /// The Developer Mode toggle (and the Developer Tools surface it reveals)
    /// compiles into local Pro DEBUG builds only — never a Release binary — so
    /// end users can't reach the diagnostic harness or the HTML Web Inspector.
    /// "Log Files" stays in every Pro build so users can still grab logs for a
    /// bug report.
    @ViewBuilder
    private var advancedSection: some View {
        Section {
            #if DEBUG && !LITE_BUILD
            SettingRow(
                icon: "wrench.and.screwdriver",
                iconColor: .orange,
                title: "Developer Mode",
                subtitle: "Show Developer Tools in the sidebar and enable right-click Inspect Element on web wallpapers.",
                info: "When on, web wallpapers open with WebKit's Web Inspector accessible — right-click in a webview wallpaper to inspect. Recommended only when debugging your own content."
            ) {
                Toggle("", isOn: $developerModeEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: developerModeEnabled) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Developer Mode"))
                    .accessibilityHint(Text("Reveals diagnostic tools and the web inspector. Off by default."))
            }
            #endif

            SettingRow(
                icon: "doc.on.doc",
                iconColor: .blue,
                title: "Copy Diagnostic Summary",
                subtitle: "Copy a sanitized system and runtime summary."
            ) {
                Button("Copy") { copyDiagnosticsSummary() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(Text("Copy diagnostic summary"))
            }

            SettingRow(
                icon: "square.and.arrow.up",
                iconColor: .blue,
                title: "Export Diagnostics",
                subtitle: "Save a sanitized diagnostic report as a text file."
            ) {
                Button("Export…") { beginDiagnosticsExport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(Text("Export diagnostics"))
            }

            SettingRow(
                icon: "ladybug",
                iconColor: .red,
                title: "Report a Bug",
                subtitle: "Review diagnostics before opening a GitHub issue."
            ) {
                Button("Open…") { presentBugReport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(Text("Report a bug"))
            }

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
        } header: {
            Text("Advanced", comment: "Section header for diagnostics and developer settings.")
        }
    }

    /// Flipping it drives `SystemAudioCaptureManager` directly so the tap
    /// starts/stops live, in addition to persisting for next launch.
    @ViewBuilder
    private var audioResponseSection: some View {
        #if !LITE_BUILD
        Section {
            SettingRow(
                icon: "waveform",
                iconColor: audioResponseEnabled ? audioStatusColor : .pink,
                title: "Audio Response",
                subtitle: "Let audio-reactive wallpapers move with the music and sound playing on your Mac.",
                info: "Analyzes your Mac's audio output on-device to compute a frequency spectrum for audio-reactive scenes. Nothing is recorded, saved, or sent anywhere. macOS asks for permission the first time you turn this on."
            ) {
                HStack(spacing: 8) {
                    if audioResponseEnabled {
                        SettingsStatusPill(text: audioStatusText, color: audioStatusColor)
                            .help(Text(verbatim: audioStatusSubtitle))
                    }

                    if audioShowsRegrant {
                        Button("Re-grant Access") {
                            regrantAudioAccess()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel(Text("Re-grant audio access"))
                    }

                    Toggle("", isOn: $audioResponseEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: audioResponseEnabled) { _, newValue in
                            updateGlobalSettings()
                            SystemAudioCaptureManager.shared.setEnabled(newValue)
                            audioCaptureState = SystemAudioCaptureManager.shared.state
                            if newValue {
                                scheduleSystemStatusRefresh(.audioCapture)
                            } else {
                                audioStatusRefreshPending = false
                            }
                        }
                        .accessibilityLabel(Text("Audio Response"))
                        .accessibilityHint(Text("Lets wallpapers react to the audio playing on your Mac. Off by default; requires audio-recording permission."))
                }
            }
        } header: {
            Text("Audio", comment: "Section header for the audio-response toggle in General settings.")
        }
        #endif
    }

    // MARK: - General Sections

    /// Per-screen RAM budget for the in-memory video cache. Slider (not a
    /// 3-mode picker) so each user picks their own RAM-vs-disk-reads trade-off.
    /// 0 = streaming only; the "total" line makes the multi-screen multiplier explicit.
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

            SettingRow(
                icon: "rectangle.on.rectangle",
                iconColor: .purple,
                title: "Pause when windows cover the desktop",
                subtitle: "Pause when app windows cover most of the screen, even without full-screen",
                info: "When open windows cover about 85 percent or more of a display, the wallpaper pauses to free CPU and GPU. It resumes as soon as you reveal the desktop."
            ) {
                Toggle("", isOn: $pauseOnWindowOcclusion)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: pauseOnWindowOcclusion) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause when windows cover the desktop"))
                    .accessibilityHint(Text("Pause when other apps' windows cover at least 85 percent of a display"))
            }

            #if !LITE_BUILD
            SettingRow(
                icon: "gauge.with.dots.needle.33percent",
                iconColor: .teal,
                title: "Reduce frame rate when covered",
                subtitle: "Lower the frame rate when windows cover the desktop or on battery, to save power",
                info: "When windows cover about half the screen, or your Mac is unplugged and wallpapers keep playing, the frame rate drops to about half to save GPU power. Full speed returns once the desktop is visible again. Affects scene (Wallpaper Engine) wallpapers."
            ) {
                Toggle("", isOn: $adaptiveFrameRateEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: adaptiveFrameRateEnabled) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Reduce frame rate when covered"))
                    .accessibilityHint(Text("Lower the frame rate when windows cover the desktop or on battery, to save power"))
            }
            #endif

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
                    // (maxWidth: .infinity, layoutPriority 1) starves the button and clips its label to an empty border.
                    .fixedSize()
                    .accessibilityLabel(Text("Edit application exceptions"))
            }

            SettingRow(
                icon: "memorychip",
                iconColor: .pink,
                title: "Video preload (RAM)",
                subtitle: "Preload video loops into memory to reduce disk reads",
                info: "Caching keeps each looping video in RAM so it doesn't re-read your disk every cycle — saving SSD wear and power. Drag to Off to stream straight from disk and use the least memory. The value below is the budget per screen (and the total across all displays)."
            ) {
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
                        Text("Video preload (RAM)")
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
                    .accessibilityLabel(Text("Video preload (RAM)"))
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

    /// `150 MB · 300 MB total` (per-screen · total). Off collapses to
    /// "Streaming only" to avoid a misleading "0 MB total".
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

    @ViewBuilder
    private var weatherSection: some View {
        Section {
            SettingRow(
                icon: "cloud.sun",
                iconColor: weatherShowsInlineStatus ? weatherPermissionColor : .cyan,
                title: "Weather Location",
                subtitle: "Where weather-reactive effects read conditions"
            ) {
                HStack(spacing: 8) {
                    if weatherShowsInlineStatus {
                        SettingsStatusPill(text: weatherPermissionText, color: weatherPermissionColor)
                            .help(Text(verbatim: weatherPermissionSubtitle))
                    }

                    if weatherShowsGrantButton {
                        Button(weatherGrantButtonTitle) {
                            handleWeatherGrantAction()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                    }

                    Picker("Source", selection: weatherSourceBinding) {
                        Text("Off").tag(WeatherLocationPreference.Source.off)
                        Text("System").tag(WeatherLocationPreference.Source.coreLocation)
                        Text("Manual").tag(WeatherLocationPreference.Source.manual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(Text("Weather location source"))
                }
            }

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

        } header: {
            Text("Weather")
        } footer: {
            Text("System uses Location Services; Manual lets you pick a city. Powers rain, snow, and fog effects.")
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
                if newValue == .coreLocation {
                    scheduleSystemStatusRefresh(.weatherLocation)
                } else {
                    weatherStatusRefreshPending = false
                    refreshLocationAuthorizationStatus()
                }
            }
        )
    }

    private func persistWeatherLocation() {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.weatherLocation = weatherLocation
        SettingsManager.shared.saveGlobalSettings(settings)
        postSettingsNotificationAsync(.weatherLocationPreferenceDidChange)
        refreshLocationAuthorizationStatus()
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
                    .font(DesignTokens.Typography.hero)
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
                        // Can't cast `NSApplication.shared.delegate` to our AppDelegate:
                        // it's SwiftUI's internal wrapper around `@NSApplicationDelegateAdaptor`.
                        // AppDelegate observes `.showOnboarding` instead.
                        NotificationCenter.default.post(name: .showOnboarding, object: nil)
                    }
                )
            }
        }
        .frame(maxWidth: 360)
    }

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

    // MARK: - Backup & Restore

    @ViewBuilder
    private var backupSection: some View {
        Section {
            SettingRow(
                icon: "square.and.arrow.up",
                iconColor: .blue,
                title: "Export Configuration",
                subtitle: "Save settings, display defaults, bookmarks, and per-display setup to a .lwconfig file",
                info: "The bundle includes global preferences, display defaults, wallpaper library bookmarks, and per-display playback / effect setup. Wallpaper files themselves are not copied — only references to them."
            ) {
                Button("Export…") { beginExport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityHint(Text("Save the current settings, display defaults, bookmarks, and per-display setup to a backup file"))
            }

            SettingRow(
                icon: "square.and.arrow.down",
                iconColor: .blue,
                title: "Import Configuration",
                subtitle: "Restore from a previously exported .lwconfig file",
                info: "Importing replaces the current global preferences, display defaults, and per-display setup. Bookmarks from the backup are merged into your library — existing entries with the same source are kept."
            ) {
                Button("Import…") { beginImport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityHint(Text("Restore settings, display defaults, bookmarks, and per-display setup from a backup file"))
            }
        } header: {
            Text("Backup & Restore")
        } footer: {
            Text("Backups store settings and references to your wallpaper files, not the files themselves — the originals must exist on the Mac you restore to.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func presentBugReport() {
        pendingBugReport = makeDiagnosticsReport()
    }

    private func copyDiagnosticsSummary() {
        let report = makeDiagnosticsReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.diagnosticMarkdown, forType: .string)
    }

    private func beginDiagnosticsExport() {
        diagnosticsDocument = DiagnosticDocument(text: makeDiagnosticsReport().diagnosticMarkdown)
        isPresentingDiagnosticsExporter = true
    }

    private func makeDiagnosticsReport() -> BugReport {
        BugReporter.makeReport(activeWallpaperKinds: activeWallpaperKinds)
    }

    private var activeWallpaperKinds: [String] {
        screenManager.wallpaperSessionSummaries
            .compactMap { $0.wallpaperType?.rawValue }
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

    // MARK: - Inline Status

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

    #if !LITE_BUILD
    private var audioStatusText: String {
        guard audioResponseEnabled else { return "Off" }
        if audioStatusRefreshPending {
            return "Checking…"
        }
        switch audioCaptureState {
        case .capturing:
            return "Granted"
        case .failed:
            return "Needs Access"
        case .unsupported:
            return "Unsupported"
        case .idle:
            return "Not Granted"
        }
    }

    private var audioStatusSubtitle: String {
        guard audioResponseEnabled else { return "Audio response is off" }
        if audioStatusRefreshPending {
            return "Waiting for macOS to update audio permission"
        }
        switch audioCaptureState {
        case .capturing:
            return "System audio capture is running"
        case .failed(let reason):
            return PIISanitizer.scrub(reason)
        case .unsupported:
            return "Requires macOS 14.2 or later"
        case .idle:
            return "Turn on access to start system audio capture"
        }
    }

    private var audioStatusColor: Color {
        guard audioResponseEnabled else { return .secondary }
        if audioStatusRefreshPending {
            return .secondary
        }
        switch audioCaptureState {
        case .capturing:
            return DesignTokens.Colors.Status.active
        case .failed:
            return DesignTokens.Colors.Status.danger
        case .unsupported:
            return DesignTokens.Colors.Status.warning
        case .idle:
            return DesignTokens.Colors.Status.warning
        }
    }

    private var audioShowsRegrant: Bool {
        guard audioResponseEnabled, !audioStatusRefreshPending else { return false }
        switch audioCaptureState {
        case .capturing, .unsupported:
            return false
        case .failed, .idle:
            return true
        }
    }

    private func regrantAudioAccess() {
        audioResponseEnabled = true
        updateGlobalSettings()
        SystemAudioCaptureManager.shared.retryAccessRequest()
        audioCaptureState = SystemAudioCaptureManager.shared.state
        scheduleSystemStatusRefresh(.audioCapture)
    }
    #endif

    private var weatherPermissionText: String {
        if weatherStatusRefreshPending, weatherLocation.source == .coreLocation {
            return "Checking…"
        }
        switch weatherLocation.source {
        case .off:
            return "Off"
        case .manual:
            return weatherLocation.manual == nil ? "Manual Needed" : "Manual"
        case .coreLocation:
            return locationAuthorizationStatus.displayTitle
        }
    }

    private var weatherPermissionSubtitle: String {
        if weatherStatusRefreshPending, weatherLocation.source == .coreLocation {
            return "Waiting for macOS to update Location Services status"
        }
        switch weatherLocation.source {
        case .off:
            return "Weather effects are disabled"
        case .manual:
            return weatherLocation.manual == nil ? "Choose a manual location" : "Using manual location"
        case .coreLocation:
            return locationAuthorizationStatus.displaySubtitle
        }
    }

    private var weatherPermissionColor: Color {
        if weatherStatusRefreshPending, weatherLocation.source == .coreLocation {
            return .secondary
        }
        switch weatherLocation.source {
        case .off, .manual:
            return .secondary
        case .coreLocation:
            return locationAuthorizationStatus.displayColor
        }
    }

    private var weatherShowsGrantButton: Bool {
        guard weatherLocation.source == .coreLocation, !weatherStatusRefreshPending else { return false }
        switch locationAuthorizationStatus {
        case .notDetermined, .denied, .restricted:
            return true
        default:
            return false
        }
    }

    private var weatherGrantButtonTitle: String {
        switch locationAuthorizationStatus {
        case .notDetermined:
            return "Re-grant Access"
        default:
            return "Open"
        }
    }

    private var weatherShowsInlineStatus: Bool {
        switch weatherLocation.source {
        case .off:
            false
        case .manual:
            weatherLocation.manual == nil
        case .coreLocation:
            true
        }
    }

    private func handleWeatherGrantAction() {
        switch locationAuthorizationStatus {
        case .notDetermined:
            screenManager.weatherService.requestLocationAuthorizationIfNeeded()
            screenManager.weatherService.refresh()
            scheduleSystemStatusRefresh(.weatherLocation)
        default:
            openLocationServicesSettings()
            scheduleSystemStatusRefresh(.weatherLocation)
        }
    }

    private func refreshLocationAuthorizationStatus() {
        locationAuthorizationStatus = CLLocationManager().authorizationStatus
    }

    private func refreshSystemStatusIndicators() {
        loginItemStatus = SMAppService.mainApp.status
        #if !LITE_BUILD
        audioCaptureState = SystemAudioCaptureManager.shared.state
        #endif
        refreshLocationAuthorizationStatus()
    }

    private func scheduleSystemStatusRefresh(_ scope: SystemStatusScope) {
        let generation = nextStatusRefreshGeneration(for: scope)
        setStatusRefreshPending(true, for: scope)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            refreshSystemStatus(for: scope)
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            refreshSystemStatus(for: scope)
            finishStatusRefresh(generation: generation, for: scope)
        }
    }

    private func nextStatusRefreshGeneration(for scope: SystemStatusScope) -> Int {
        switch scope {
        case .loginItem:
            loginItemStatusRefreshGeneration += 1
            return loginItemStatusRefreshGeneration
        case .audioCapture:
            #if !LITE_BUILD
            audioStatusRefreshGeneration += 1
            return audioStatusRefreshGeneration
            #else
            return 0
            #endif
        case .weatherLocation:
            weatherStatusRefreshGeneration += 1
            return weatherStatusRefreshGeneration
        }
    }

    private func setStatusRefreshPending(_ pending: Bool, for scope: SystemStatusScope) {
        switch scope {
        case .loginItem:
            loginItemStatusRefreshPending = pending
        case .audioCapture:
            #if !LITE_BUILD
            audioStatusRefreshPending = pending
            #endif
        case .weatherLocation:
            weatherStatusRefreshPending = pending
        }
    }

    private func refreshSystemStatus(for scope: SystemStatusScope) {
        switch scope {
        case .loginItem:
            loginItemStatus = SMAppService.mainApp.status
        case .audioCapture:
            #if !LITE_BUILD
            if audioResponseEnabled, SystemAudioCaptureManager.shared.state != .capturing {
                SystemAudioCaptureManager.shared.retryAccessRequest()
            }
            audioCaptureState = SystemAudioCaptureManager.shared.state
            #endif
        case .weatherLocation:
            refreshLocationAuthorizationStatus()
        }
    }

    private func finishStatusRefresh(generation: Int, for scope: SystemStatusScope) {
        switch scope {
        case .loginItem:
            guard loginItemStatusRefreshGeneration == generation else { return }
            loginItemStatusRefreshPending = false
            loginItemStatus = SMAppService.mainApp.status
        case .audioCapture:
            #if !LITE_BUILD
            guard audioStatusRefreshGeneration == generation else { return }
            audioStatusRefreshPending = false
            audioCaptureState = SystemAudioCaptureManager.shared.state
            #endif
        case .weatherLocation:
            guard weatherStatusRefreshGeneration == generation else { return }
            weatherStatusRefreshPending = false
            refreshLocationAuthorizationStatus()
        }
    }

    private func openLocationServicesSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
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
        settings.adaptiveFrameRateEnabled = adaptiveFrameRateEnabled
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
    /// the SwiftUI reconcile pass that triggered the save.
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

}

private struct SettingsStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(DesignTokens.Typography.captionEmphasized)
            .foregroundStyle(color)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.24), lineWidth: 0.5))
            .fixedSize()
    }
}

private extension CLAuthorizationStatus {
    var displayTitle: String {
        switch self {
        case .authorizedAlways, .authorizedWhenInUse:
            return "Granted"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Determined"
        @unknown default:
            return "Unknown"
        }
    }

    var displaySubtitle: String {
        switch self {
        case .authorizedAlways, .authorizedWhenInUse:
            return "Location Services access is granted"
        case .denied:
            return "Allow access in Location Services"
        case .restricted:
            return "Location Services is restricted on this Mac"
        case .notDetermined:
            return "macOS has not asked for Location Services yet"
        @unknown default:
            return "macOS returned an unknown location status"
        }
    }

    var displayColor: Color {
        switch self {
        case .authorizedAlways, .authorizedWhenInUse:
            return DesignTokens.Colors.Status.active
        case .denied, .restricted:
            return DesignTokens.Colors.Status.danger
        case .notDetermined:
            return DesignTokens.Colors.Status.warning
        @unknown default:
            return .secondary
        }
    }
}
