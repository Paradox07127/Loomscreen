import SwiftUI
import AppKit
import Combine

@MainActor
class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let screenManager: ScreenManager
    private var settingsWindowController: NSWindowController?
    private var cleanupTasks = Set<AnyCancellable>()

    // MARK: - Initialization

    init(screenManager: ScreenManager) {
        self.screenManager = screenManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusItem()
        setupPlaybackObservers()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        updateStatusBarIcon()
        button.image?.isTemplate = true
        button.toolTip = "LiveWallpaper"
        setupMenu()
    }

    // MARK: - Status Bar Icon

    private func updateStatusBarIcon(isPlaying: Bool? = nil) {
        guard let button = statusItem.button else { return }

        let isAnyPlaying = isPlaying ?? screenManager.screens.contains { $0.videoPlayer?.isPlaying ?? false }
        let symbolName = determineStatusBarIcon(isAnyPlaying: isAnyPlaying)

        guard button.image?.name() != symbolName else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "LiveWallpaper")
            button.image?.isTemplate = true
        }
    }

    private func determineStatusBarIcon(isAnyPlaying: Bool) -> String {
        if screenManager.screens.allSatisfy({ $0.videoPlayer == nil }) {
            return "photo.on.rectangle"
        } else if isAnyPlaying {
            return "play.rectangle.fill"
        } else {
            return "pause.rectangle.fill"
        }
    }
    
    // MARK: - Observers

    private func setupPlaybackObservers() {
        // Playback state changes
        screenManager.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] isPlaying in self?.updateStatusBarIcon(isPlaying: isPlaying) }
            .store(in: &cleanupTasks)

        // Screen refresh events
        NotificationCenter.default.publisher(for: .init("ScreensRefreshed"))
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.updateStatusBarIcon()
                if self?.statusItem.button?.isHighlighted == true {
                    self?.updateDisplaysMenu()
                }
            }
            .store(in: &cleanupTasks)

        // Power state changes
        NotificationCenter.default.publisher(for: PowerMonitor.powerSourceDidChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusBarIcon(isPlaying: self?.screenManager.isAnyScreenPlaying)
            }
            .store(in: &cleanupTasks)

        // Initial icon update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateStatusBarIcon(isPlaying: self?.screenManager.isAnyScreenPlaying)
        }
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

        // Settings menu item (⌘,)
        let settingsItem = createMenuItem(
            title: "Open Settings...",
            action: #selector(showSettings),
            keyEquivalent: ",",
            modifiers: .command
        )
        settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")

        // Displays submenu
        let displaysMenu = NSMenu()
        let displaysItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        displaysItem.submenu = displaysMenu

        // Playback control items (⌘P)
        let playPauseItem = createMenuItem(
            title: "Play/Pause All",
            action: #selector(togglePlayback),
            keyEquivalent: "p",
            modifiers: .command
        )
        playPauseItem.image = NSImage(systemSymbolName: "playpause", accessibilityDescription: "Play/Pause")

        // Reload all videos (⌘R)
        let reloadItem = createMenuItem(
            title: "Reload All Videos",
            action: #selector(reloadAllVideos),
            keyEquivalent: "r",
            modifiers: .command
        )
        reloadItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")

        // Quit item (⌘Q)
        let quitItem = createMenuItem(
            title: "Quit LiveWallpaper",
            action: #selector(NSApplication.terminate),
            keyEquivalent: "q",
            modifiers: .command
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
        menu.addItem(reloadItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
    }
    
    private func createMenuItem(title: String, action: Selector?, keyEquivalent: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }
    
    // MARK: - Settings Window Management
    
    @objc private func showSettings() {
        Logger.info("Opening settings window", category: .ui)
        
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
        NSApp.activate()
    }
    
    // MARK: - Playback Control

    @objc private func togglePlayback() {
        screenManager.togglePlayback()
    }

    @objc private func reloadAllVideos() {
        Logger.info("Reloading all videos via menu shortcut", category: .ui)
        screenManager.reloadAllScreens()
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
    }
    
    deinit {
        cleanupTasks.removeAll()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - NSWindowDelegate
extension StatusBarController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindowController = nil
    }
}
