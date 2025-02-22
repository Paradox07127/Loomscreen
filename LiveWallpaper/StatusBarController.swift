import SwiftUI
import AppKit

class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var screenManager: ScreenManager
    private var mainWindow: NSWindow?
    
    init(screenManager: ScreenManager) {
        self.screenManager = screenManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        super.init()
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Live Wallpaper")
            button.image?.isTemplate = true
        }
        
        setupMenu()
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        
        // Settings window item
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(showMainWindow(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let playPauseItem = NSMenuItem(title: "Play/Pause", action: #selector(togglePlayback(_:)), keyEquivalent: "p")
        playPauseItem.target = self
        menu.addItem(playPauseItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc private func showMainWindow(_ sender: NSMenuItem) {
        if let mainWindow = self.mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let contentView = ContentView()
            .environmentObject(screenManager)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        window.makeKeyAndOrderFront(nil)
        
        self.mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        if let playPauseItem = menu.items.first(where: { $0.action == #selector(togglePlayback(_:)) }) {
            let isPlaying = screenManager.screens.first?.videoPlayer?.isPlaying ?? false
            playPauseItem.title = isPlaying ? "Pause" : "Play"
        }
    }
    
    @objc private func togglePlayback(_ sender: NSMenuItem) {
        screenManager.screens.forEach { screen in
            screen.videoPlayer?.togglePlayback()
        }
    }
    
    @objc private func quit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
}
