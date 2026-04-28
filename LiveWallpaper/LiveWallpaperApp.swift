import SwiftUI
import AppKit

/// App startup workflow:
/// 1. `applicationDidFinishLaunching` builds ScreenManager only after NSApp's main
///    loop is ready (earlier construction trips NSScreen/NSApp asserts in FullScreenDetector).
/// 2. `screenManager` is `@Observable` so its nil → non-nil transition re-renders
///    `LiveWallpaperApp.body`'s MenuBarExtra contents.
/// 3. Settings is opened via a hand-managed `NSWindowController` to avoid SwiftUI's
///    `Settings { ... }` scene applying the macOS System Settings styling.
@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    var screenManager: ScreenManager?

    @ObservationIgnored private var settingsWindowController: NSWindowController?
    @ObservationIgnored private var onboardingWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.notice("Application starting", category: .startup)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeNotification),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        let manager = ScreenManager()
        screenManager = manager
        manager.refreshScreens()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            manager.reloadAllScreens()
        }

        NSApp.setActivationPolicy(.accessory)
        Logger.notice("Application startup complete", category: .startup)

        if !UserDefaults.standard.bool(forKey: "Onboarding.Completed") {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    @objc private func handleWakeNotification() {
        Logger.info("System wake detected", category: .lifecycle)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.screenManager?.refreshScreens()
            PowerMonitor.shared.refreshPowerStatus()
        }
    }

    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Settings Window

    /// Open (or front) the Settings window. `initialScreenID` is used to jump
    /// straight to a specific display from the menubar's per-screen submenu.
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
            // On multi-display / background process: NSApp.activate() alone doesn't
            // raise the window. Explicit makeKey + orderFrontRegardless guarantees visibility.
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

    /// Show (or front) the first-run onboarding flow. Triggered automatically
    /// on first launch and re-triggerable from GeneralSettingsView.
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
        // MenuBarExtra is the SwiftUI replacement for NSStatusItem (macOS 13+).
        // The label closure provides the status-bar icon; @Observable AppDelegate auto-refreshes.
        MenuBarExtra {
            menuBarBody
        } label: {
            Image(systemName: menuBarIconName)
        }
        // .window style lets us pop a custom SwiftUI panel from the status bar:
        // mini dashboard + per-screen cards + quick toggles + Settings/Quit footer.
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

    /// Mirrors the legacy `StatusBarController.determineStatusBarIcon` logic.
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
