import SwiftUI
import AppKit
import LiveWallpaperCore

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
            memoryPressureWatcher: SystemMemoryPressureWatcher.shared,
            featureCatalog: FeatureCatalog(capabilities: .lite),
            originReconciler: PreservingOriginReconciler()
        )
        #else
        // Build-target-only capabilities are layered on here rather than baked
        // into the shipping Pro catalog because Xcode does not propagate app
        // compilation conditions into local SwiftPM packages.
        let shippingProCapabilities = ProductCapabilities.pro.withWorkshopOnline()
        #if DEBUG
        let proCapabilities = shippingProCapabilities.withLocalDeveloperTools()
        #else
        let proCapabilities = shippingProCapabilities
        #endif
        screenManagerOptions = ScreenManagerStartupOptions(
            restoreSavedWallpapers: runtimeOptions.shouldRestoreSavedWallpapers,
            startAutomation: runtimeOptions.shouldStartAutomation,
            memoryPressureWatcher: SystemMemoryPressureWatcher.shared,
            featureCatalog: FeatureCatalog(capabilities: proCapabilities)
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
    // Floor must fit the sidebar plus the shared library-page floor. Workshop
    // can also open an inspector inside that detail column, so width keeps the
    // previous compressed-grid budget while height tracks the shared page token.
    static let minimumContentSize = CGSize(width: 1160, height: DesignTokens.LibraryPage.minHeight)
}

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    var screenManager: ScreenManager?

    @ObservationIgnored private let runtimeOptions = AppRuntimeOptions()
    @ObservationIgnored private var settingsWindowController: NSWindowController?
    @ObservationIgnored private var settingsOwnsSystemMonitorLease = false
    @ObservationIgnored private var onboardingWindowController: NSWindowController?
    /// See `WeatherReactiveService.preferenceObserver` — same pattern.
    @ObservationIgnored nonisolated(unsafe) private var dockVisibilityObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var showOnboardingObserver: NSObjectProtocol?
    @ObservationIgnored private var globalShortcutManager: GlobalShortcutManager?
    @ObservationIgnored private let lifecycle = ApplicationLifecycleController()
    #if !LITE_BUILD
    /// Pro only: lives for the lifetime of the app so the
    /// Doctor's probe state survives Settings-window close / re-open and the
    /// Workshop tab can read it without re-running probes.
    @ObservationIgnored private let workshopDoctorService = SteamCMDDoctorService()
    /// Bundles the Keychain + QueryService + on-disk QueryCache actors for
    /// the v3 online-browse flow. Lives for the lifetime of the app so the
    /// in-flight coalescing + token bucket survive Settings-window cycles.
    @ObservationIgnored private let workshopServices = WorkshopServices()
    #endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.notice("Application starting", category: .startup)
        if let hint = LogFileSink.shared.tailCommandHint {
            Logger.notice("Tail the runtime log → \(hint)", category: .startup)
        }

        #if !LITE_BUILD
        // Reclaim WPE package staging dirs orphaned by a prior session's
        // abnormal termination (deinit never ran). Runs off-main and before any
        // scene provider is created, so it can't race a live provider's dir.
        if !runtimeOptions.isTesting {
            WPEPackageSceneAssetProvider.sweepStaleStagingDirectoriesAtLaunch()
        }
        #endif

        let startupPlan = AppStartupPlan(
            runtimeOptions: runtimeOptions,
            onboardingCompleted: UserDefaults.standard.bool(forKey: "Onboarding.Completed")
        )

        #if !LITE_BUILD
        if !runtimeOptions.isTesting {
            lifecycle.schedule { [weak self] in
                guard let self, self.lifecycle.allowsWork else { return }
                // ScreenManager.refreshScreens() restores WPE sessions from its
                // initializer. Select the authoritative managed-assets slot first;
                // otherwise WPEEngineAssetsLibrary can observe a crash-cut tree.
                await WPEEngineAssetsStartupRecovery.shared.prepareForFirstRead()
                guard self.lifecycle.allowsWork else { return }
                self.completeApplicationStartup(startupPlan)
            }
            return
        }
        #endif
        completeApplicationStartup(startupPlan)
    }

    private func completeApplicationStartup(_ startupPlan: AppStartupPlan) {
        guard lifecycle.allowsWork, screenManager == nil else { return }
        let manager = ScreenManager(startupOptions: startupPlan.screenManagerOptions)
        screenManager = manager

        if manager.featureCatalog.isEnabled(.html) {
            HTMLWallpaperView.precompileTrackerRules()
        }

        if startupPlan.refreshScreensAfterManagerCreation {
            manager.refreshScreens()
        }

        if startupPlan.screenManagerOptions.restoreSavedWallpapers {
            lifecycle.schedule(after: .seconds(1)) { [weak manager] in
                manager?.pruneInvalidConfigurationsIfNeeded()
            }
        }

        #if !LITE_BUILD
        // Reclaim disk for scenes the user can no longer reach. Deferred so it
        // never contends with first-frame work. First drop legacy extracted
        // `wpe-cache` directories for unreferenced ids, then reclaim video-
        // texture buckets against the *post-GC* cache contents (so a just-
        // removed orphan's videos go too).
        if !runtimeOptions.isTesting, manager.featureCatalog.isEnabled(.wpeImport) {
            lifecycle.schedule(after: .seconds(2)) {
                let keepIDs = WPESceneReachability.referencedWorkshopIDs()
                let cache = WallpaperEngineCache.shared
                await cache.collectOrphans(keepIDs: keepIDs)
                var referenced = keepIDs
                referenced.formUnion(await cache.listAvailableWorkshopIDs())
                await WPEVideoTextureDiskCache.shared.collectOrphans(referencedWorkshopIDs: referenced)
            }
        }
        #endif

        applyDockVisibility()
        observeDockVisibilityChanges()
        observeShowOnboardingRequests()

        if !runtimeOptions.isTesting,
           manager.featureCatalog.isEnabled(.globalShortcuts) {
            globalShortcutManager = GlobalShortcutManager(screenManager: manager)
            globalShortcutManager?.start()
        }

        // Floating fleet HUD (Pro-only): restore the user's persisted on/off
        // state. Independent of the Monitor wallpaper — it manages its own
        // agents-only runtime lease while shown.
        if !runtimeOptions.isTesting,
           manager.featureCatalog.isEnabled(.agentFleet) {
            MonitorHUDController.shared.focusHandler = { MonitorFocusRouter.focus(sessionID: $0) }
            MonitorHUDController.shared.applyPersistedStateAtStartup()
        }

        // Monitor overlay layer: restore any per-display overlay the user left on,
        // floating the widget board over whatever wallpaper each display shows.
        if !runtimeOptions.isTesting {
            manager.reconcileMonitorOverlays()
        }

        Logger.notice("Application startup complete", category: .startup)

        if startupPlan.showSettingsOnLaunch {
            Logger.info("Scheduling settings window on launch", category: .startup)
            lifecycle.schedule(after: .milliseconds(150)) { [weak self] in
                self?.showSettings()
            }
        } else if startupPlan.showOnboarding {
            lifecycle.schedule { [weak self] in
                self?.showOnboarding()
            }
        } else {
            scheduleSettingsWindowPrewarm()
        }

        #if !LITE_BUILD
        // Resume system-audio capture if the user left audio response on. The
        // shared manager owns the single tap; sinks read its broker.
        if !runtimeOptions.isTesting {
            let audioResponseEnabled = SettingsManager.shared.loadGlobalSettings().audioResponseEnabled
            SystemAudioCaptureManager.shared.setEnabled(audioResponseEnabled)
        }

        #endif

        #if !LITE_BUILD
        // Auto-run the Workshop Doctor once at launch when it's already
        // configured, so the in-app "Download from Steam" path is ready without
        // a manual probe run. Deferred + background; skipped when unconfigured
        // (nothing meaningful to probe) so users who never set up SteamCMD pay
        // no launch cost.
        if !runtimeOptions.isTesting,
           workshopDoctorService.binaryBookmarkData != nil,
           workshopDoctorService.workdirBookmarkData != nil {
            lifecycle.schedule(after: .seconds(3)) { [workshopDoctorService] in
                await workshopDoctorService.runAll()
            }
        }
        #endif

        #if LITE_BUILD
        // Loomscreen Lite ships ad-hoc signed via GitHub Releases, so we
        // hand-roll a single-shot launch-time update check (no background
        // timer, throttled to 12 h in UpdateChecker itself). Skip it on
        // first-run onboarding so a brand-new user doesn't get a network
        // prompt before they see their first wallpaper.
        if !startupPlan.showOnboarding && !runtimeOptions.isTesting {
            lifecycle.schedule(after: .seconds(5)) {
                await UpdateChecker.shared.checkNow(force: false)
            }
        }
        #endif
    }

    deinit {
        if let observer = dockVisibilityObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showOnboardingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Dock Visibility

    private func applyDockVisibility() {
        guard lifecycle.allowsWork else { return }
        let showInDock = SettingsManager.shared.loadGlobalSettings().showInDock
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
    }

    private func observeDockVisibilityChanges() {
        guard lifecycle.allowsWork else { return }
        dockVisibilityObserver = NotificationCenter.default.addObserver(
            forName: .dockVisibilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lifecycle.allowsWork else { return }
                self.applyDockVisibility()
            }
        }
    }

    private func observeShowOnboardingRequests() {
        guard lifecycle.allowsWork else { return }
        showOnboardingObserver = NotificationCenter.default.addObserver(
            forName: .showOnboarding,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lifecycle.allowsWork else { return }
                self.showOnboarding()
            }
        }
    }

    private func removeLifecycleObservers() {
        if let observer = dockVisibilityObserver {
            NotificationCenter.default.removeObserver(observer)
            dockVisibilityObserver = nil
        }
        if let observer = showOnboardingObserver {
            NotificationCenter.default.removeObserver(observer)
            showOnboardingObserver = nil
        }
    }

    private func closeApplicationWindowsForTermination() {
        releaseSettingsSystemMonitorLeaseIfNeeded()
        settingsWindowController?.window?.delegate = nil
        settingsWindowController?.close()
        settingsWindowController = nil
        onboardingWindowController?.window?.delegate = nil
        onboardingWindowController?.close()
        onboardingWindowController = nil
    }

    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Tears down render sessions (pauses AVPlayers, releases WKWebViews / Metal
    /// renderers — so WebKit's SQLite/WAL closes cleanly and no video/snapshot
    /// staging is left mid-write), awaits the Monitor producer graph, then drains
    /// cursor + settings persistence. The whole async barrier is capped by a
    /// watchdog so a stuck source or disk write cannot hold quit indefinitely.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch lifecycle.beginTermination() {
        case .wait:
            return .terminateLater
        case .terminateNow:
            return .terminateNow
        case .begin:
            break
        }

        globalShortcutManager?.stop()
        globalShortcutManager = nil
        removeLifecycleObservers()
        closeApplicationWindowsForTermination()
        SystemMonitor.shared.shutdown()
        screenManager?.tearDownForTermination()
        #if !LITE_BUILD
        SystemAudioCaptureManager.shared.shutdown()
        #endif

        Task { @MainActor [weak self] in
            // Reply on whichever lands first: the ordered shutdown, or a 2s
            // watchdog. The work is intentionally not cancelled when the
            // watchdog wins: persistence writes may not honor cancellation, and
            // the process can still finish useful cleanup before AppKit exits.
            let reply = { [weak self] in
                guard let self, self.lifecycle.markReplied() else { return }
                sender.reply(toApplicationShouldTerminate: true)
            }
            let watchdog = Task {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                reply()
            }

            await AppTerminationCoordinator.shutdownForApplication()
            watchdog.cancel()
            reply()
        }
        return .terminateLater
    }

    // MARK: - Settings Window

    private func scheduleSettingsWindowPrewarm() {
        guard !runtimeOptions.isTesting, lifecycle.allowsWork else { return }

        lifecycle.schedule(after: .milliseconds(1_200)) { [weak self] in
            self?.prewarmSettingsWindow()
        }
    }

    func prewarmSettingsWindow() {
        guard lifecycle.allowsWork,
              settingsWindowController == nil,
              let manager = screenManager
        else { return }

        settingsWindowController = makeSettingsWindowController(
            manager: manager,
            initialNavigation: nil,
            initialAddWallpaperPromptKind: nil
        )
        Logger.info("Settings window prewarmed", category: .ui)
    }

    func showSettings(
        initialScreenID: CGDirectDisplayID? = nil,
        initialAddWallpaperPromptKind: String? = nil,
        opensGeneralSettings: Bool = false
    ) {
        guard lifecycle.allowsWork, let manager = screenManager else { return }
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
        let baseContentView = ContentView(
            initialNavigation: initialNavigation,
            initialAddWallpaperPromptKind: initialAddWallpaperPromptKind
        )
            .environment(manager)
            .environment(\.featureCatalog, manager.featureCatalog)

        #if !LITE_BUILD
        let contentView = baseContentView
            .environment(workshopDoctorService)
            .environment(workshopServices)
            .appLanguageScoped()
        #else
        let contentView = baseContentView
            .appLanguageScoped()
        #endif

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
        // Pair with `windowShouldClose` returning false: the close button
        // only `orderOut`s the window so the warmed NavigationSplitView
        // state survives. `isReleasedWhenClosed = false` keeps AppKit from
        // releasing the NSWindow if anything else routes through the real
        // close path (e.g. app quit).
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        window.setFrameAutosaveName("LiveWallpaperSettingsWindow")

        return NSWindowController(window: window)
    }

    private func presentSettingsWindow(_ controller: NSWindowController) {
        controller.showWindow(nil)
        guard let window = controller.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        guard window.isVisible else { return }
        acquireSettingsSystemMonitorLeaseIfNeeded()
    }

    private func acquireSettingsSystemMonitorLeaseIfNeeded() {
        guard !settingsOwnsSystemMonitorLease,
              screenManager?.featureCatalog.isEnabled(.systemMonitor) == true else { return }
        settingsOwnsSystemMonitorLease = true
        SystemMonitor.shared.startMonitoring()
    }

    private func releaseSettingsSystemMonitorLeaseIfNeeded() {
        guard settingsOwnsSystemMonitorLease else { return }
        settingsOwnsSystemMonitorLease = false
        SystemMonitor.shared.stopMonitoring()
    }

    private func postSettingsWindowRequest(
        initialScreenID: CGDirectDisplayID?,
        initialAddWallpaperPromptKind: String?,
        opensGeneralSettings: Bool
    ) {
        lifecycle.schedule { [weak self] in
            guard let self, self.lifecycle.allowsWork else { return }
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

    /// Shows the first-run onboarding flow. Also used by the General Settings
    /// "Welcome Tour" tile to re-trigger the tour after first-run.
    func showOnboarding() {
        guard lifecycle.allowsWork else { return }
        Logger.info("Onboarding window requested", category: .ui)

        if let controller = onboardingWindowController {
            Logger.info("Onboarding window reused", category: .ui)
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
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

        let flow = OnboardingFlow(
            onClose: { [weak self] in
                self?.onboardingWindowController?.close()
            },
            onShowAppleAerials: { [weak self] in
                guard let self, self.lifecycle.allowsWork else { return }
                self.showSettings()
                self.lifecycle.schedule { [weak self] in
                    guard let self, self.lifecycle.allowsWork else { return }
                    NotificationCenter.default.post(name: .openAppleAerials, object: nil)
                }
            }
        )

        if let manager = screenManager {
            let base = flow
                .environment(manager)
                .environment(\.featureCatalog, manager.featureCatalog)
            #if !LITE_BUILD
            window.contentView = NSHostingView(
                rootView: base
                    .environment(workshopDoctorService)
                    .environment(workshopServices)
                    .appLanguageScoped()
            )
            #else
            window.contentView = NSHostingView(rootView: base.appLanguageScoped())
            #endif
        } else {
            Logger.warning("Onboarding shown without ScreenManager — Pro picker will fail to render", category: .ui)
            window.contentView = NSHostingView(rootView: flow.appLanguageScoped())
        }

        window.delegate = self

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.orderFrontRegardless()
        Logger.info("Onboarding window shown", category: .ui)
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Redirect the settings-window close to `orderOut(nil)` so the warmed
    /// NavigationSplitView / NSSplitViewController state survives — a full
    /// close+reopen re-pays the sidebar-bridge materialization cost on the next
    /// reveal even when the NSWindowController is retained. Onboarding keeps the
    /// regular close-and-release semantics.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == settingsWindowController?.window {
            releaseSettingsSystemMonitorLeaseIfNeeded()
            sender.orderOut(nil)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }

        if closingWindow == settingsWindowController?.window {
            releaseSettingsSystemMonitorLeaseIfNeeded()
            return
        }

        if closingWindow == onboardingWindowController?.window {
            onboardingWindowController = nil
            return
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == settingsWindowController?.window else { return }
        releaseSettingsSystemMonitorLeaseIfNeeded()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard lifecycle.allowsWork,
              let window = notification.object as? NSWindow,
              window == settingsWindowController?.window,
              window.isVisible else { return }
        acquireSettingsSystemMonitorLeaseIfNeeded()
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
                },
                openSettingsAndAddWallpaper: { [appDelegate] in
                    appDelegate.showSettings(initialAddWallpaperPromptKind: "video")
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
        case .off:
            return "rectangle.slash"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}
