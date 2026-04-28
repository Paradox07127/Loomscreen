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

/// App delegate owns startup and the hand-managed settings/onboarding windows.
@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    var screenManager: ScreenManager?

    @ObservationIgnored private let runtimeOptions = AppRuntimeOptions()
    @ObservationIgnored private var settingsWindowController: NSWindowController?
    @ObservationIgnored private var onboardingWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.notice("Application starting", category: .startup)

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

        NSApp.setActivationPolicy(.accessory)
        Logger.notice("Application startup complete", category: .startup)

        if startupPlan.showOnboarding {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Settings Window

    /// Opens settings, optionally selecting a display from the menu bar.
    func showSettings(initialScreenID: CGDirectDisplayID? = nil) {
        guard let manager = screenManager else { return }

        if let controller = settingsWindowController {
            controller.showWindow(nil)
            if let id = initialScreenID {
                NotificationCenter.default.post(
                    name: .selectScreenInSettings,
                    object: nil,
                    userInfo: ["screenID": id]
                )
            }
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.orderFrontRegardless()
            return
        }

        let initialNavigation: Navigation? = initialScreenID.map { .screen($0) }
        let contentView = ContentView(initialNavigation: initialNavigation)
            .environment(manager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
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
