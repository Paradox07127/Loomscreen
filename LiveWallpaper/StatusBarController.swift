import SwiftUI
import AppKit

class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let screenManager: ScreenManager
    private var settingsWindowController: NSWindowController?
    
    init(screenManager: ScreenManager) {
        self.screenManager = screenManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        super.init()
        configureStatusItem()
    }
    
    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: "Live Wallpaper")
            button.image?.isTemplate = true
        }
        setupMenu()
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        
        // Settings menu item
        let settingsItem = createMenuItem(
            title: "Settings",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        
        // Display submenu
        let displaysMenu = NSMenu()
        let displaysItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        displaysItem.submenu = displaysMenu
        
        // Playback control
        let playPauseItem = createMenuItem(
            title: "Play/Pause All",
            action: #selector(togglePlayback),
            keyEquivalent: "p"
        )
        
        // Quit item
        let quitItem = createMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        
        // Add items to menu
        menu.addItem(settingsItem)
        menu.addItem(displaysItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(playPauseItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    private func createMenuItem(title: String, action: Selector?, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }
    
    @objc private func showSettings() {
        // Return if window already exists and just needs to be shown
        if let windowController = settingsWindowController {
            windowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create new settings window
        let contentView = ContentView()
            .environmentObject(screenManager)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        // Configure window appearance
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.center()
        
        // Set up content
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        
        // Create and store window controller
        let windowController = NSWindowController(window: window)
        settingsWindowController = windowController
        
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func togglePlayback() {
        screenManager.screens.forEach { screen in
            screen.videoPlayer?.togglePlayback()
        }
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        updateDisplaysMenu()
        updatePlaybackMenuState()
    }
    
    private func updateDisplaysMenu() {
        guard let menu = statusItem.menu,
              let displaysItem = menu.items.first(where: { $0.title == "Displays" }),
              let displaysMenu = displaysItem.submenu else { return }
        
        // Clear existing items
        displaysMenu.removeAllItems()
        
        // Add items for each screen
        for screen in screenManager.screens {
            let item = NSMenuItem(title: screen.name, action: nil, keyEquivalent: "")
            item.isEnabled = true
            
            if screen.videoPlayer != nil {
                item.state = .on
            }
            
            displaysMenu.addItem(item)
        }
    }
    
    private func updatePlaybackMenuState() {
        guard let menu = statusItem.menu,
              let playPauseItem = menu.items.first(where: { $0.action == #selector(togglePlayback) }) else { return }
        
        let isAnyPlaying = screenManager.screens.contains { $0.videoPlayer?.isPlaying ?? false }
        playPauseItem.title = isAnyPlaying ? "Pause All" : "Play All"
    }
}

extension StatusBarController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindowController = nil
    }
}
