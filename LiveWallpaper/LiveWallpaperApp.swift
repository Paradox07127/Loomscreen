import SwiftUI
import AppKit

struct AppRuntimeOptions: Equatable {
    let isTesting: Bool

    var shouldRestoreSavedWallpapers: Bool { !isTesting }
    var shouldStartAutomation: Bool { !isTesting }
    var shouldShowOnboarding: Bool { !isTesting }

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isXCTestLoaded: Bool = AppRuntimeOptions.isXCTestLoaded()
    ) {
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

    init(runtimeOptions: AppRuntimeOptions, onboardingCompleted: Bool) {
        screenManagerOptions = ScreenManagerStartupOptions(
            restoreSavedWallpapers: runtimeOptions.shouldRestoreSavedWallpapers,
            startAutomation: runtimeOptions.shouldStartAutomation
        )
        refreshScreensAfterManagerCreation = false
        reloadWallpapersAfterLaunch = false
        showOnboarding = runtimeOptions.shouldShowOnboarding && !onboardingCompleted
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.notice("Application starting", category: .startup)

        // 把 tracker rule list 提前编译进 WKContentRuleListStore，
        // 后续 HTML 壁纸首次启用过滤时直接 lookUp，省掉同步编译开销。
        HTMLWallpaperView.precompileTrackerRules()

        let startupPlan = AppStartupPlan(
            runtimeOptions: runtimeOptions,
            onboardingCompleted: UserDefaults.standard.bool(forKey: "Onboarding.Completed")
        )
        let manager = ScreenManager(startupOptions: startupPlan.screenManagerOptions)
        screenManager = manager

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

        if !runtimeOptions.isTesting {
            globalShortcutManager = GlobalShortcutManager(screenManager: manager)
            globalShortcutManager?.start()
        }

        Logger.notice("Application startup complete", category: .startup)

        if startupPlan.showOnboarding {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
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

    // MARK: - Settings Window

    /// Opens settings, optionally selecting a display from the menu bar.
    /// `initialAddWallpaperPromptKind`, when non-nil, is consumed by
    /// `ContentView.onAppear` to launch the matching picker — this replaces
    /// the racy `dismiss + DispatchQueue.async + post` chain that the menu
    /// bar previously used to hand off picker requests.
    func showSettings(initialScreenID: CGDirectDisplayID? = nil, initialAddWallpaperPromptKind: String? = nil) {
        guard let manager = screenManager else { return }

        if let controller = settingsWindowController {
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.orderFrontRegardless()
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
            return
        }

        let initialNavigation: Navigation? = initialScreenID.map { .screen($0) }
        let contentView = ContentView(
            initialNavigation: initialNavigation,
            initialAddWallpaperPromptKind: initialAddWallpaperPromptKind
        )
            .environment(manager)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowMetrics.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = SettingsWindowMetrics.minimumContentSize
        window.title = "LiveWallpaper Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        window.setFrameAutosaveName("LiveWallpaperSettingsWindow")

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        onboardingWindowController = controller

        let flow = OnboardingFlow(onClose: { [weak self] in
            self?.onboardingWindowController?.close()
        })

        if let manager = screenManager {
            window.contentView = NSHostingView(rootView: flow.environment(manager))
        } else {
            window.contentView = NSHostingView(rootView: flow)
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
                    appDelegate.showSettings()
                },
                openSettingsForScreen: { [appDelegate] id in
                    appDelegate.showSettings(initialScreenID: id)
                },
                promptAddWallpaper: { [appDelegate] kind in
                    appDelegate.showSettings(initialAddWallpaperPromptKind: kind)
                }
            )
            .environment(screenManager)
        } else {
            Text("Initializing…")
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
