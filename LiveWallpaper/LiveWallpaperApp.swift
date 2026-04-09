import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    var screenManager: ScreenManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.notice("Application starting", category: .startup)

        // Register for sleep/wake notifications early
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeNotification),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Initialize and keep reference to ScreenManager
        screenManager = ScreenManager()

        if let manager = screenManager {
            manager.refreshScreens()
            statusBarController = StatusBarController(screenManager: manager)

            // Load and apply configurations after a short delay
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                manager.reloadAllScreens()
            }
        } else {
            Logger.error("ScreenManager failed to initialize", category: .startup)
        }

        NSApp.setActivationPolicy(.accessory)
        Logger.notice("Application startup complete", category: .startup)
    }

    @objc private func handleWakeNotification() {
        Logger.info("System wake detected", category: .lifecycle)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.screenManager?.refreshScreens()
            // Refresh power status as well
            PowerMonitor.shared.refreshPowerStatus()
        }
    }

    /// Opt in to secure window state restoration (required on macOS Sonoma+).
    /// Even though we don't restore any windows in a status-bar app, returning
    /// `true` silences the framework's "Unable to find className=(null)" log
    /// from `NSWindowRestoration` and is the recommended modern default.
    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
