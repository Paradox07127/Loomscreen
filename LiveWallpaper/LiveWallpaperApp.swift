import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    var screenManager: ScreenManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("App launching: initializing ScreenManager.")
        
        // Register for sleep/wake notifications early
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeNotification),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        screenManager = ScreenManager()
        
        if let manager = screenManager {
            print("Initializing StatusBarController.")
            statusBarController = StatusBarController(screenManager: manager)
            
            // Validate configurations on startup with a delay to ensure system is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                print("Performing startup configuration validation")
                self.validateConfigurations()
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
        print("System woke from sleep")
        // Give the system a moment to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.screenManager?.refreshScreens()
            // Refresh power status as well
            PowerMonitor.shared.refreshPowerStatus()
        }
    }
    
    private func validateConfigurations() {
        guard let screenManager = screenManager else { return }
        
        // Get all screen configurations
        let configurations = SettingsManager.shared.loadConfigurations()
        print("Found \(configurations.count) configurations to validate")
        
        var validConfigs = 0
        var invalidConfigs = 0
        
        // Validate each configuration
        for config in configurations {
            if SettingsManager.shared.validateConfiguration(for: config.screenID) {
                validConfigs += 1
            } else {
                invalidConfigs += 1
                print("Invalid configuration found for screen \(config.screenID)")
            }
        }
        
        print("Startup validation complete: \(validConfigs) valid, \(invalidConfigs) invalid configurations")
        
        // Check if current screens match configuration
        let configuredScreenIDs = Set(configurations.map { $0.screenID })
        let connectedScreenIDs = Set(screenManager.screens.map { $0.id })
        
        let unconfiguredScreens = connectedScreenIDs.subtracting(configuredScreenIDs)
        let disconnectedConfigs = configuredScreenIDs.subtracting(connectedScreenIDs)
        
        print("Unconfigured screens: \(unconfiguredScreens.count)")
        print("Configurations for disconnected screens: \(disconnectedConfigs.count)")
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
