import SwiftUI
import AppKit

struct AppRuntimeOptions: Equatable {
    let isTesting: Bool
    let opensSettingsForUITesting: Bool

    var shouldRestoreSavedWallpapers: Bool { !isTesting }
    var shouldStartAutomation: Bool { !isTesting }
    var shouldShowOnboarding: Bool { !isTesting }
    var shouldOpenSettingsOnLaunch: Bool { opensSettingsForUITesting }

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isXCTestLoaded: Bool = AppRuntimeOptions.isXCTestLoaded()
    ) {
        opensSettingsForUITesting = arguments.contains("--open-settings-for-ui-testing")
            || environment["LIVEWALLPAPER_OPEN_SETTINGS"] == "1"
        isTesting = arguments.contains("--ui-testing")
            || environment["LIVEWALLPAPER_TESTING"] == "1"
            || environment["LIVEWALLPAPER_UI_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment.keys.contains { $0.localizedCaseInsensitiveContains("XCTest") }
            || isXCTestLoaded
    }

    private static func isXCTestLoaded() -> Bool {
        NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }
}

struct AppStartupPlan: Equatable {
    let screenManagerOptions: ScreenManagerStartupOptions
    let refreshScreensAfterManagerCreation: Bool
    let reloadWallpapersAfterLaunch: Bool
    let showOnboarding: Bool
    let showSettingsOnLaunch: Bool

    init(runtimeOptions: AppRuntimeOptions, onboardingCompleted: Bool) {
        #if LITE_BUILD
        screenManagerOptions = ScreenManagerStartupOptions(
            restoreSavedWallpapers: runtimeOptions.shouldRestoreSavedWallpapers,
            startAutomation: runtimeOptions.shouldStartAutomation,
            featureCatalog: FeatureCatalog(capabilities: .lite),
            originReconciler: PreservingOriginReconciler()
        )
        #else
        screenManagerOptions = ScreenManagerStartupOptions(
            restoreSavedWallpapers: runtimeOptions.shouldRestoreSavedWallpapers,
            startAutomation: runtimeOptions.shouldStartAutomation
        )
        #endif
        refreshScreensAfterManagerCreation = false
        reloadWallpapersAfterLaunch = false
        showOnboarding = runtimeOptions.shouldShowOnboarding && !onboardingCompleted
        showSettingsOnLaunch = runtimeOptions.shouldOpenSettingsOnLaunch
    }
}

enum SettingsWindowMetrics {
    static let sidebarColumnWidth = DesignTokens.Sidebar.width
    static let sidebarColumnMaxWidth = DesignTokens.Sidebar.maxWidth
    static let defaultContentSize = CGSize(width: 1180, height: 720)
    static let minimumContentSize = CGSize(width: 1080, height: 650)
}

/// App delegate owns startup and the hand-managed settings/onboarding windows.
@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    var screenManager: ScreenManager?

    @ObservationIgnored private let runtimeOptions = AppRuntimeOptions()
    @ObservationIgnored private var settingsWindowController: NSWindowController?
    @ObservationIgnored private var onboardingWindowController: NSWindowController?
    /// See `WeatherReactiveService.preferenceObserver` — same pattern.
    @ObservationIgnored nonisolated(unsafe) private var dockVisibilityObserver: NSObjectProtocol?
    @ObservationIgnored private var globalShortcutManager: GlobalShortcutManager?
    /// True between the first `.terminateLater` reply and the matching
    /// `reply(toApplicationShouldTerminate:)`. Re-entrant termination
    /// attempts skip the flush so we don't enqueue duplicate writes that
    /// could outlive the app.
    @ObservationIgnored private var isWaitingForTerminationFlush = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.notice("Application starting", category: .startup)
        if let hint = LogFileSink.shared.tailCommandHint {
            // Print as a notice so the next-most-recent line in Console.app
            // gives maintainers a copy-pastable follow command without
            // having to guess the sandbox container path.
            Logger.notice("Tail the runtime log → \(hint)", category: .startup)
        }

        let startupPlan = AppStartupPlan(
            runtimeOptions: runtimeOptions,
            onboardingCompleted: UserDefaults.standard.bool(forKey: "Onboarding.Completed")
        )
        let manager = ScreenManager(startupOptions: startupPlan.screenManagerOptions)
        screenManager = manager

        // Tracker-rule precompile is a Pro-side warmup — it pays for itself
        // only when HTML tracker-blocking is reachable. The rule list still
        // compiles lazily on first use, so skipping this preserves
        // functionality and saves ~tens of ms at cold start.
        if manager.featureCatalog.isEnabled(.html) {
            HTMLWallpaperView.precompileTrackerRules()
        }

        if startupPlan.refreshScreensAfterManagerCreation {
            manager.refreshScreens()
        }

        // Light async pass: drops configurations whose video bookmark cannot
        // be resolved any more. Replaces the legacy heavy reloadAllScreens.
        if startupPlan.screenManagerOptions.restoreSavedWallpapers {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                manager.pruneInvalidConfigurationsIfNeeded()
            }
        }

        applyDockVisibility()
        observeDockVisibilityChanges()

        if !runtimeOptions.isTesting,
           manager.featureCatalog.isEnabled(.globalShortcuts) {
            globalShortcutManager = GlobalShortcutManager(screenManager: manager)
            globalShortcutManager?.start()
        }

        Logger.notice("Application startup complete", category: .startup)

        if startupPlan.showSettingsOnLaunch {
            Logger.info("Scheduling settings window on launch", category: .startup)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                self?.showSettings()
            }
        } else if startupPlan.showOnboarding {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        } else {
            scheduleSettingsWindowPrewarm()
        }
    }

    deinit {
        if let observer = dockVisibilityObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Dock Visibility

    /// Reads the persisted preference and applies the matching activation
    /// policy. `.regular` shows the app in Dock + Cmd-Tab; `.accessory`
    /// hides it back into the menu bar (current default).
    private func applyDockVisibility() {
        let showInDock = SettingsManager.shared.loadGlobalSettings().showInDock
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
    }

    private func observeDockVisibilityChanges() {
        dockVisibilityObserver = NotificationCenter.default.addObserver(
            forName: .dockVisibilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyDockVisibility()
            }
        }
    }

    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Drains the async persistence actor before exit so the last UI commits
    /// (typically a toggle the user flipped just before Cmd-Q) are durable
    /// on disk. `.terminateLater` keeps AppKit from tearing the process
    /// down until the flush task signals back.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isWaitingForTerminationFlush else { return .terminateNow }
        isWaitingForTerminationFlush = true
        Task { @MainActor in
            await SettingsManager.shared.flushPendingConfigurationWrites()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Settings Window

    private func scheduleSettingsWindowPrewarm() {
        guard !runtimeOptions.isTesting else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.prewarmSettingsWindow()
        }
    }

    func prewarmSettingsWindow() {
        guard settingsWindowController == nil,
              let manager = screenManager
        else { return }

        settingsWindowController = makeSettingsWindowController(
            manager: manager,
            initialNavigation: nil,
            initialAddWallpaperPromptKind: nil
        )
        Logger.info("Settings window prewarmed", category: .ui)
    }

    /// Opens settings, optionally selecting a display from the menu bar.
    /// `initialAddWallpaperPromptKind`, when non-nil, is consumed by
    /// `ContentView.onAppear` to launch the matching picker — this replaces
    /// the racy `dismiss + DispatchQueue.async + post` chain that the menu
    /// bar previously used to hand off picker requests.
    func showSettings(
        initialScreenID: CGDirectDisplayID? = nil,
        initialAddWallpaperPromptKind: String? = nil,
        opensGeneralSettings: Bool = false
    ) {
        guard let manager = screenManager else { return }
        Logger.info("Settings window requested", category: .ui)

        if let controller = settingsWindowController {
            presentSettingsWindow(controller)
            Logger.info("Settings window reused", category: .ui)
            postSettingsWindowRequest(
                initialScreenID: initialScreenID,
                initialAddWallpaperPromptKind: initialAddWallpaperPromptKind,
                opensGeneralSettings: opensGeneralSettings
            )
            return
        }

        let initialNavigation: Navigation? = opensGeneralSettings ? .general : initialScreenID.map { .screen($0) }
        let controller = makeSettingsWindowController(
            manager: manager,
            initialNavigation: initialNavigation,
            initialAddWallpaperPromptKind: initialAddWallpaperPromptKind
        )
        settingsWindowController = controller
        presentSettingsWindow(controller)
        Logger.info("Settings window shown", category: .ui)
    }

    private func makeSettingsWindowController(
        manager: ScreenManager,
        initialNavigation: Navigation?,
        initialAddWallpaperPromptKind: String?
    ) -> NSWindowController {
        let contentView = ContentView(
            initialNavigation: initialNavigation,
            initialAddWallpaperPromptKind: initialAddWallpaperPromptKind
        )
            .environment(manager)
            .environment(\.featureCatalog, manager.featureCatalog)
            .appLanguageScoped()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowMetrics.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = SettingsWindowMetrics.minimumContentSize
        window.title = L10n.Window.settingsTitle
        window.setAccessibilityTitle(L10n.Window.settingsTitle)
        window.setAccessibilityIdentifier("LiveWallpaperSettingsWindow")
        window.sharingType = .readOnly
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = false
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        window.setFrameAutosaveName("LiveWallpaperSettingsWindow")

        return NSWindowController(window: window)
    }

    private func presentSettingsWindow(_ controller: NSWindowController) {
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
    }

    private func postSettingsWindowRequest(
        initialScreenID: CGDirectDisplayID?,
        initialAddWallpaperPromptKind: String?,
        opensGeneralSettings: Bool
    ) {
        DispatchQueue.main.async {
            if opensGeneralSettings {
                NotificationCenter.default.post(name: .openGeneralSettings, object: nil)
            }
            if let id = initialScreenID {
                NotificationCenter.default.post(
                    name: .selectScreenInSettings,
                    object: nil,
                    userInfo: ["screenID": id]
                )
            }
            if let kind = initialAddWallpaperPromptKind {
                NotificationCenter.default.post(
                    name: .promptAddWallpaper,
                    object: nil,
                    userInfo: ["kind": kind]
                )
            }
        }
    }

    // MARK: - Onboarding Window

    /// Shows the first-run onboarding flow.
    func showOnboarding() {
        if let controller = onboardingWindowController {
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        onboardingWindowController = controller

        let flow = OnboardingFlow(onClose: { [weak self] in
            self?.onboardingWindowController?.close()
        })

        if let manager = screenManager {
            window.contentView = NSHostingView(
                rootView: flow
                    .environment(manager)
                    .environment(\.featureCatalog, manager.featureCatalog)
                    .appLanguageScoped()
            )
        } else {
            window.contentView = NSHostingView(rootView: flow.appLanguageScoped())
        }

        window.delegate = self

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }

        if closingWindow == settingsWindowController?.window {
            settingsWindowController = nil
            return
        }
        if closingWindow == onboardingWindowController?.window {
            onboardingWindowController = nil
            return
        }
    }
}

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            menuBarBody
        } label: {
            Image(systemName: menuBarIconName)
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarBody: some View {
        if let screenManager = appDelegate.screenManager {
            MenuBarContent(
                openSettings: { [appDelegate] in
                    appDelegate.showSettings(opensGeneralSettings: true)
                },
                openSettingsForScreen: { [appDelegate] id in
                    appDelegate.showSettings(initialScreenID: id)
                }
            )
            .environment(screenManager)
            .environment(\.featureCatalog, screenManager.featureCatalog)
            .appLanguageScoped()
        } else {
            Text("Initializing…")
                .appLanguageScoped()
        }
    }

    private var menuBarIconName: String {
        guard let manager = appDelegate.screenManager else {
            return "photo.on.rectangle"
        }
        switch manager.wallpaperOverviewStatus {
        case .notConfigured:
            return "photo.on.rectangle"
        case .active:
            return manager.hasControllableWallpaperSessions
                ? "play.rectangle.fill"
                : "display.2"
        case .paused:
            return "pause.rectangle.fill"
        }
    }
}
