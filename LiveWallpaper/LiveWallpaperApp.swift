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
        // Direct-distribution Pro: layer `.workshopOnline` onto the Pro catalog.
        // The conditional lives here (not in `ProductCapabilities.pro` where it
        // logically belongs) because Xcode does not propagate
        // `SWIFT_ACTIVE_COMPILATION_CONDITIONS` from the app target into local
        // SwiftPM packages. MAS / non-direct-distribution Pro builds omit the
        // `DIRECT_DISTRIBUTION` flag and the capability stays out.
        #if DIRECT_DISTRIBUTION
        let proCapabilities = ProductCapabilities.pro.withWorkshopOnline()
        #else
        let proCapabilities = ProductCapabilities.pro
        #endif
        screenManagerOptions = ScreenManagerStartupOptions(
            restoreSavedWallpapers: runtimeOptions.shouldRestoreSavedWallpapers,
            startAutomation: runtimeOptions.shouldStartAutomation,
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
    // Floor must fit sidebar + a compressed library grid + the detail inspector
    // at its 300pt minimum (it opens trailing inside the detail column). 1080
    // left the inspector clipping past the window's right edge at min width.
    static let minimumContentSize = CGSize(width: 1160, height: 540)
}

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    var screenManager: ScreenManager?

    @ObservationIgnored private let runtimeOptions = AppRuntimeOptions()
    @ObservationIgnored private var settingsWindowController: NSWindowController?
    @ObservationIgnored private var onboardingWindowController: NSWindowController?
    /// See `WeatherReactiveService.preferenceObserver` — same pattern.
    @ObservationIgnored nonisolated(unsafe) private var dockVisibilityObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var showOnboardingObserver: NSObjectProtocol?
    @ObservationIgnored private var globalShortcutManager: GlobalShortcutManager?
    #if !LITE_BUILD && DIRECT_DISTRIBUTION
    /// Direct-distribution Pro only: lives for the lifetime of the app so the
    /// Doctor's probe state survives Settings-window close / re-open and the
    /// Workshop tab can read it without re-running probes.
    @ObservationIgnored private let workshopDoctorService = SteamCMDDoctorService()
    /// Bundles the Keychain + QueryService + on-disk QueryCache actors for
    /// the v3 online-browse flow. Lives for the lifetime of the app so the
    /// in-flight coalescing + token bucket survive Settings-window cycles.
    @ObservationIgnored private let workshopServices = WorkshopServices()
    #endif
    /// True between the first `.terminateLater` reply and the matching
    /// `reply(toApplicationShouldTerminate:)`. Re-entrant termination
    /// attempts skip the flush so we don't enqueue duplicate writes that
    /// could outlive the app.
    @ObservationIgnored private var isWaitingForTerminationFlush = false

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
        let manager = ScreenManager(startupOptions: startupPlan.screenManagerOptions)
        screenManager = manager

        if manager.featureCatalog.isEnabled(.html) {
            HTMLWallpaperView.precompileTrackerRules()
        }

        if startupPlan.refreshScreensAfterManagerCreation {
            manager.refreshScreens()
        }

        if startupPlan.screenManagerOptions.restoreSavedWallpapers {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                manager.pruneInvalidConfigurationsIfNeeded()
            }
        }

        #if !LITE_BUILD
        // Reclaim disk for scenes the user can no longer reach. Deferred so it
        // never contends with first-frame work. First drop legacy extracted
        // `wpe-cache` directories for unreferenced ids, then reclaim video-
        // texture buckets against the *post-GC* cache contents (so a just-
        // removed orphan's videos go too).
        if !runtimeOptions.isTesting, manager.featureCatalog.isEnabled(.wpeImport) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let keepIDs = WPESceneReachability.referencedWorkshopIDs()
                let cache = WallpaperEngineCache()
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

        #if !LITE_BUILD
        // Resume system-audio capture if the user left audio response on. The
        // shared manager owns the single tap; sinks read its broker.
        if !runtimeOptions.isTesting {
            let audioResponseEnabled = SettingsManager.shared.loadGlobalSettings().audioResponseEnabled
            SystemAudioCaptureManager.shared.setEnabled(audioResponseEnabled)
        }

        // On-device verification hook for the system-audio capture tap. No-op
        // unless `WPEAudioCaptureProbe` default is set. See SystemAudioCaptureProbe.
        if #available(macOS 14.2, *), !runtimeOptions.isTesting {
            SystemAudioCaptureProbe.runIfRequested()
        }
        #endif

        #if LITE_BUILD
        // Loomscreen Lite ships ad-hoc signed via GitHub Releases, so we
        // hand-roll a single-shot launch-time update check (no background
        // timer, throttled to 12 h in UpdateChecker itself). Skip it on
        // first-run onboarding so a brand-new user doesn't get a network
        // prompt before they see their first wallpaper.
        if !startupPlan.showOnboarding && !runtimeOptions.isTesting {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
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

    private func observeShowOnboardingRequests() {
        showOnboardingObserver = NotificationCenter.default.addObserver(
            forName: .showOnboarding,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showOnboarding()
            }
        }
    }

    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Tears down render sessions (pauses AVPlayers, releases WKWebViews / Metal
    /// renderers — so WebKit's SQLite/WAL closes cleanly and no video/snapshot
    /// staging is left mid-write) and drains the async persistence actor before
    /// exit, so the last UI commits (typically a toggle flipped just before
    /// Cmd-Q) are durable on disk. The teardown is in-process and bounded; the
    /// flush is the only awaited work and is capped by a watchdog so a stuck
    /// disk write can't hold the quit past the system terminate deadline.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isWaitingForTerminationFlush else { return .terminateNow }
        isWaitingForTerminationFlush = true
        screenManager?.tearDownForTermination()
        Task { @MainActor in
            // Reply on whichever lands first: the flush, or a 2s watchdog. The
            // persistence-actor writes don't honor cancellation, so we don't
            // cancel the flush — we just stop *waiting* on it once the deadline
            // passes, so a stuck disk write can't hold the quit past the system
            // terminate watchdog. `replied` guards the single allowed reply.
            var replied = false
            let reply = {
                guard !replied else { return }
                replied = true
                sender.reply(toApplicationShouldTerminate: true)
            }
            let flush = Task { await SettingsManager.shared.flushPendingConfigurationWrites() }
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(2))
                reply()
            }
            await flush.value
            watchdog.cancel()
            reply()
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
        let baseContentView = ContentView(
            initialNavigation: initialNavigation,
            initialAddWallpaperPromptKind: initialAddWallpaperPromptKind
        )
            .environment(manager)
            .environment(\.featureCatalog, manager.featureCatalog)

        #if !LITE_BUILD && DIRECT_DISTRIBUTION
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

    /// Shows the first-run onboarding flow. Also used by the General Settings
    /// "Welcome Tour" tile to re-trigger the tour after first-run.
    func showOnboarding() {
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
                self?.showSettings()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .openAppleAerials, object: nil)
                }
            }
        )

        if let manager = screenManager {
            let base = flow
                .environment(manager)
                .environment(\.featureCatalog, manager.featureCatalog)
            #if !LITE_BUILD && DIRECT_DISTRIBUTION
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
            sender.orderOut(nil)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }

        // The settings window never reaches here — windowShouldClose
        // suppresses the close. Only onboarding cleans up its controller.
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
