import SwiftUI

@main
struct LiveWallpaperApp: App {
    @StateObject private var screenManager = ScreenManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(screenManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
