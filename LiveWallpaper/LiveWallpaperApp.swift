import SwiftUI

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
        Logger.debug("Registered for wake notifications", category: .startup)
        
        // Initialize and keep reference to ScreenManager
        screenManager = ScreenManager()
        
        if let manager = screenManager {
            Logger.info("ScreenManager initialized", category: .startup)
            
            // Initialize screens first
            Logger.debug("Performing initial screen configuration", category: .screenManager)
            manager.refreshScreens()
            
            // Now that screens are configured, set up the status bar
            statusBarController = StatusBarController(screenManager: manager)
            Logger.info("Status bar controller initialized", category: .startup)
            
            // Load and apply configurations after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Logger.debug("Loading saved configurations", category: .screenManager)
                manager.reloadAllScreens()
            }
        } else {
            Logger.error("ScreenManager failed to initialize", category: .startup)
        }
        
        // Hide dock icon for a menu-bar app
        NSApp.setActivationPolicy(.accessory)
        
        // Setup automatic updates for screens when configurations change
        setupConfigurationObserver()
        Logger.notice("Application startup complete", category: .startup)
    }
    
    private func setupConfigurationObserver() {
        // Monitor UserDefaults changes for configuration updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }
    
    @objc private func handleConfigurationChange() {
        // This could be called frequently, so we use debouncing
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reloadScreenConfigurations), object: nil)
        perform(#selector(reloadScreenConfigurations), with: nil, afterDelay: 1.0)
    }
    
    @objc private func reloadScreenConfigurations() {
        screenManager?.reloadAllScreens()
    }
    
    @objc private func handleWakeNotification() {
        Logger.info("System wake detected", category: .lifecycle)
        // Give the system a moment to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Logger.debug("Refreshing screens after wake", category: .screenManager)
            self?.screenManager?.refreshScreens()
            // Refresh power status as well
            PowerMonitor.shared.refreshPowerStatus()
        }
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
