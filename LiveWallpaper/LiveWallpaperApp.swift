import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    var screenManager: ScreenManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("App launching: initializing ScreenManager.")
        screenManager = ScreenManager()
        if let manager = screenManager {
            print("Initializing StatusBarController.")
            statusBarController = StatusBarController(screenManager: manager)
        } else {
            print("Error: ScreenManager failed to initialize.")
        }
        
        // Hide dock icon for a menu-bar app
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()  // No content is shown by default
        }
    }
}
