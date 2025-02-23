import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    var screenManager: ScreenManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        screenManager = ScreenManager()
        statusBarController = StatusBarController(screenManager: screenManager!)
        
        // Hide dock icon since we're primarily a menu bar app
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            if let screenManager = appDelegate.screenManager {
                ContentView()
                    .environmentObject(screenManager)
            }
        }
        .windowStyle(.automatic)  // Change to automatic window style
        .windowToolbarStyle(.unified)  // Add unified toolbar style
        .defaultSize(width: 0, height: 0)
    }
}
