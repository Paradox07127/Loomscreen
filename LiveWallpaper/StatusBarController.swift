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
        
        // Displays submenu
        let displaysMenu = NSMenu()
        let displaysItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        displaysItem.submenu = displaysMenu
        
        // Playback control item
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
        
        // Assemble menu
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
    
    // MARK: - Settings Window Management
    
    @objc private func showSettings() {
        // If the settings window already exists, show it.
        if let windowController = settingsWindowController {
            windowController.showWindow(nil)
            activateApp()
            return
        }
        
        // Otherwise, create a new settings window.
        let window = createSettingsWindow()
        settingsWindowController = NSWindowController(window: window)
        settingsWindowController?.showWindow(nil)
        activateApp()
    }
    
    private func createSettingsWindow() -> NSWindow {
        let contentView = ContentView().environmentObject(screenManager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        // Window appearance configuration
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        
        return window
    }
    
    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Playback Control
    
    @objc private func togglePlayback() {
        for screen in screenManager.screens {
            screen.videoPlayer?.togglePlayback()
        }
        print("Playback toggled for all screens.")
    }
    
    // MARK: - Menu Delegate
    
    func menuWillOpen(_ menu: NSMenu) {
        print("Status bar menu will open.")
        updateDisplaysMenu()
        updatePlaybackMenuState()
    }
    
    private func updateDisplaysMenu() {
        guard let menu = statusItem.menu,
              let displaysItem = menu.items.first(where: { $0.title == "Displays" }),
              let displaysMenu = displaysItem.submenu else { return }
        
        displaysMenu.removeAllItems()
        for screen in screenManager.screens {
            let item = NSMenuItem(title: screen.name, action: nil, keyEquivalent: "")
            item.isEnabled = true
            if screen.videoPlayer != nil {
                item.state = .on
            }
            displaysMenu.addItem(item)
        }
        print("Displays menu updated with \(screenManager.screens.count) screens.")
    }
    
    private func updatePlaybackMenuState() {
        guard let menu = statusItem.menu,
              let playPauseItem = menu.items.first(where: { $0.action == #selector(togglePlayback) }) else { return }
        
        let isAnyPlaying = screenManager.screens.contains { $0.videoPlayer?.isPlaying ?? false }
        playPauseItem.title = isAnyPlaying ? "Pause All" : "Play All"
        print("Playback menu state updated: \(playPauseItem.title)")
    }
}

// MARK: - NSWindowDelegate

extension StatusBarController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindowController = nil
        print("Settings window closed.")
    }
}
