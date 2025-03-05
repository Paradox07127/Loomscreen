import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    var screenManager: ScreenManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register for sleep/wake notifications early
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeNotification),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        screenManager = ScreenManager()
        
        if let manager = screenManager {
            statusBarController = StatusBarController(screenManager: manager)
            
            // Initialize screens after a short delay to ensure system is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                manager.refreshScreens()
            }
        } else {
            print("Error: ScreenManager failed to initialize.")
        }
        
        // Hide dock icon for a menu-bar app
        NSApp.setActivationPolicy(.accessory)
        
        // Setup automatic updates for screens when configurations change
        setupConfigurationObserver()
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
        // Give the system a moment to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
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
