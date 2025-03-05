import SwiftUI
import AppKit

class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let screenManager: ScreenManager
    private var settingsWindowController: NSWindowController?
    private var menuUpdateTimer: Timer?
    
    init(screenManager: ScreenManager) {
        self.screenManager = screenManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusItem()
        startPeriodicMenuUpdates()
    }
    
    private func configureStatusItem() {
        if let button = statusItem.button {
            updateStatusBarIcon()
            button.image?.isTemplate = true
            button.toolTip = "LiveWallpaper"
        }
        setupMenu()
    }
    
    private func updateStatusBarIcon() {
        guard let button = statusItem.button else { return }
        
        let isAnyPlaying = screenManager.screens.contains { $0.videoPlayer?.isPlaying ?? false }
        let symbolName = isAnyPlaying ? "play.rectangle.fill" : "photo.on.rectangle"
        
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "LiveWallpaper")
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        
        // Header item with app name (non-interactive)
        let headerItem = NSMenuItem(title: "LiveWallpaper", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        headerItem.attributedTitle = NSAttributedString(
            string: "LiveWallpaper",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor
            ]
        )
        
        // Settings menu item
        let settingsItem = createMenuItem(
            title: "Open Settings...",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")
        
        // Displays submenu
        let displaysMenu = NSMenu()
        let displaysItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        displaysItem.submenu = displaysMenu
        
        // Playback control items
        let playPauseItem = createMenuItem(
            title: "Play/Pause All",
            action: #selector(togglePlayback),
            keyEquivalent: "p"
        )
        
        // Quit item
        let quitItem = createMenuItem(
            title: "Quit LiveWallpaper",
            action: #selector(NSApplication.terminate),
            keyEquivalent: "q"
        )
        quitItem.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Quit")
        quitItem.target = NSApp
        
        // Assemble menu
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(displaysItem)
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
        
        
        
        // Otherwise, create a new settings window
        let window = createSettingsWindow()
        settingsWindowController = NSWindowController(window: window)
        settingsWindowController?.showWindow(nil)
        activateApp()
    }
    
    private func showSettingsForScreen(screenID: CGDirectDisplayID) {
        // If the settings window already exists, show it and navigate to the screen
        if let windowController = settingsWindowController {
            windowController.showWindow(nil)
            
            // Notify the ContentView to navigate to the selected screen
            NotificationCenter.default.post(
                name: .init("SelectScreenInSettings"),
                object: nil,
                userInfo: ["screenID": screenID]
            )
            
            activateApp()
            return
        }
        
        // Otherwise, create a new settings window with the initial screen selection
        let window = createSettingsWindow(initialScreenID: screenID)
        settingsWindowController = NSWindowController(window: window)
        settingsWindowController?.showWindow(nil)
        activateApp()
    }
    
    private func createSettingsWindow(initialScreenID: CGDirectDisplayID? = nil) -> NSWindow {
        // Create content view with initial navigation if a screen ID is provided
        let initialNavigation: Navigation? = initialScreenID.map { .screen($0) }
        let contentView = ContentView(initialNavigation: initialNavigation).environmentObject(screenManager)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        // Window appearance configuration
        window.title = "LiveWallpaper Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        window.setFrameAutosaveName("LiveWallpaperSettingsWindow")
        
        return window
    }
    
    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Playback Control
    
    @objc private func togglePlayback() {
        // Check if any videos are playing
        let isAnyPlaying = screenManager.screens.contains { $0.videoPlayer?.isPlaying ?? false }
        
        // Toggle playback based on current state
        for screen in screenManager.screens {
            if let player = screen.videoPlayer {
                if isAnyPlaying {
                    player.pause()
                } else {
                    player.play()
                }
            }
        }
        
        DispatchQueue.main.async {
            self.updateStatusBarIcon()
        }
    }
    
    // MARK: - Menu Delegate
    
    func menuWillOpen(_ menu: NSMenu) {
        updateDisplaysMenu()
        updatePlaybackMenuState()
    }
    
    private func updateDisplaysMenu() {
        guard let menu = statusItem.menu,
              let displaysItem = menu.items.first(where: { $0.title == "Displays" }),
              let displaysMenu = displaysItem.submenu else { return }
        
        displaysMenu.removeAllItems()
        displaysItem.image = NSImage(systemSymbolName: "display", accessibilityDescription: "display icon")
        
        if screenManager.screens.isEmpty {
            let noDisplaysItem = NSMenuItem(title: "No displays detected", action: nil, keyEquivalent: "")
            noDisplaysItem.isEnabled = false
            displaysMenu.addItem(noDisplaysItem)
            return
        }
        
        for screen in screenManager.screens {
            let item = NSMenuItem(title: screen.name, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.tag = Int(screen.id) // Store the screen ID in the tag
            item.target = self
            
            // Show status icon in the menu
            if screen.videoPlayer != nil {
                let isPlaying = screen.videoPlayer?.isPlaying ?? false
                item.image = NSImage(
                    systemSymbolName: isPlaying ? "play.circle.fill" : "pause.circle.fill",
                    accessibilityDescription: isPlaying ? "Playing" : "Paused"
                )
            } else {
                item.image = NSImage(
                    systemSymbolName: "questionmark.circle",
                    accessibilityDescription: "Not configured"
                )
            }
            
            displaysMenu.addItem(item)
        }
        
        // Add refresh option
        displaysMenu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh Displays", action: #selector(refreshDisplays), keyEquivalent: "r")
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshItem.target = self
        displaysMenu.addItem(refreshItem)
    }
    
    private func updatePlaybackMenuState() {
        guard let menu = statusItem.menu,
              let playPauseItem = menu.items.first(where: { $0.action == #selector(togglePlayback) }) else { return }
        
        let isAnyPlaying = screenManager.screens.contains { $0.videoPlayer?.isPlaying ?? false }
        
        if isAnyPlaying {
            playPauseItem.title = "Pause All Videos"
            playPauseItem.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Pause")
        } else {
            playPauseItem.title = "Play All Videos"
            playPauseItem.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Play")
        }
    }
    
    @objc private func selectDisplay(_ sender: NSMenuItem) {
        let screenID = CGDirectDisplayID(sender.tag)
        showSettingsForScreen(screenID: screenID)
    }
    
    @objc private func refreshDisplays() {
        screenManager.refreshScreens()
        // Show animation in the menu bar when screens refresh
        showBriefAnimation("arrow.triangle.2.circlepath")
    }
    
    // MARK: - Animations & Visual Feedback
    
    /// Show status icon animation for brief visual feedback
    func showBriefAnimation(_ symbolName: String = "play.circle.fill") {
        guard let button = statusItem.button else { return }
        
        // Store the original image
        let originalImage = button.image
        
        // Show brief animation
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Action")
        
        // Restore original image after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.updateStatusBarIcon()
        }
    }
    
    // MARK: - Menu Auto Update
    func startPeriodicMenuUpdates() {
        // Update menu items that might change over time
        menuUpdateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Always update the icon when timer fires
            self.updateStatusBarIcon()
            
            // Check if menu might be open (button is highlighted)
            if self.statusItem.button?.isHighlighted == true {
                // Update menu items that might have changed
                self.updatePlaybackMenuState()
            }
        }
    }
    
    deinit {
        menuUpdateTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - NSWindowDelegate
extension StatusBarController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindowController = nil
    }
}
