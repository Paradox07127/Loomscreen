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

/// Composition + shared state; the section rows live in the sibling `GeneralSettings*.swift` extension files.
struct GeneralSettingsView: View {
    enum SystemStatusScope {
        case loginItem
        case audioCapture
        case weatherLocation
    }

    @Environment(ScreenManager.self) var screenManager
    @AppStorage(AppLanguagePreference.storageKey) var appLanguageRawValue = AppLanguagePreference.system.rawValue
    @State var globalPauseOnBattery: Bool
    @State var startOnLogin: Bool
    @State var loginItemStatus = SMAppService.mainApp.status
    @State var loginItemStatusRefreshPending = false
    @State private var loginItemStatusRefreshGeneration = 0
    @State var preservePlaybackOnLock: Bool
    @State var pauseOnFullScreen: Bool
    @State var pauseInGameMode: Bool
    @State var pauseOnWindowOcclusion: Bool
    @State var applicationRules: [ApplicationPerformanceRule]
    @State var showAppExceptions = false
    @State var showInDock: Bool
    /// In MB (converted to bytes on persist). `Double` for SwiftUI `Slider`;
    /// the step snaps to a `% 32 == 0` MB boundary so the label reads cleanly.
    @State var videoCacheBudgetMB: Double
    /// Hidden in Lite via `#if !LITE_BUILD` + capability gate so the row never renders.
    @State var developerModeEnabled: Bool

    /// Default off — privacy-sensitive opt-in.
    @State var audioResponseEnabled: Bool
    #if !LITE_BUILD
    @State var audioCaptureState = SystemAudioCaptureManager.shared.state
    @State var audioStatusRefreshPending = false
    @State private var audioStatusRefreshGeneration = 0
    #endif
    /// Default off — Pro-only scene power saving (adaptive frame rate).
    @State var adaptiveFrameRateEnabled: Bool
    @State var weatherLocation: WeatherLocationPreference
    @State var locationAuthorizationStatus = CLLocationManager().authorizationStatus
    @State var weatherStatusRefreshPending = false
    @State private var weatherStatusRefreshGeneration = 0

    @State var pendingBugReport: BugReport?

    @State private var loginItemAlert: LoginItemFailure?

    /// Held so the user confirms in an alert before the import is applied (staged confirm-then-apply).
    @State var pendingImportBundle: ConfigurationBundle?
    @State var pendingImportSource: URL?
    @State var importFeedback: String?
    @State var importErrorMessage: String?
    @State var exportErrorMessage: String?
    @State private var diagnosticsExportErrorMessage: String?

    /// Drives SwiftUI's native `.fileExporter` / `.fileImporter` sheets —
    /// these handle UTType filtering, sandbox extensions, and sheet
    /// modality automatically, which `NSSavePanel.runModal()` does not.
    @State var isPresentingExporter = false
    @State var isPresentingImporter = false
    @State var isPresentingDiagnosticsExporter = false
    @State var exportDocument: ConfigurationDocument?
    @State var diagnosticsDocument: DiagnosticDocument?

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

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .settingsFormChrome()
    }

    // MARK: - System Status Refresh

    private func refreshSystemStatusIndicators() {
        loginItemStatus = SMAppService.mainApp.status
        #if !LITE_BUILD
        audioCaptureState = SystemAudioCaptureManager.shared.state
        #endif
        refreshLocationAuthorizationStatus()
    }

    func scheduleSystemStatusRefresh(_ scope: SystemStatusScope) {
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

    func refreshLocationAuthorizationStatus() {
        locationAuthorizationStatus = CLLocationManager().authorizationStatus
    }

    // MARK: - Settings Persistence

    /// Persists every `@State` field this view mirrors (the full list loaded
    /// in `init`) via read-modify-write, so unrelated `GlobalSettings` fields
    /// (schedule, shortcuts, display defaults, WPE history…) survive.
    func updateGlobalSettings() {
        var settings = SettingsManager.shared.loadGlobalSettings()
        let dockChanged = settings.showInDock != showInDock
        let developerModeChanged = settings.developerModeEnabled != developerModeEnabled
        let weatherChanged = settings.weatherLocation != weatherLocation
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
        settings.weatherLocation = weatherLocation
        SettingsManager.shared.saveGlobalSettings(settings)
        screenManager.handleGlobalSettingsChanged()
        if dockChanged {
            postSettingsNotificationAsync(.dockVisibilityDidChange)
        }
        if developerModeChanged {
            postSettingsNotificationAsync(.developerModeDidChange)
        }
        if weatherChanged {
            postSettingsNotificationAsync(.weatherLocationPreferenceDidChange)
        }
    }

    /// Defers the post to the next MainActor turn so it does not fire inside
    /// the SwiftUI reconcile pass that triggered the save.
    func postSettingsNotificationAsync(_ name: Notification.Name) {
        Task { @MainActor in
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

}
