import AppKit

class VideoWallpaperWindow: NSWindow {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false  // Changed to false to ensure immediate window setup
        )
        
        // Essential settings
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        
        // Collection behavior
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        
        // Window specific settings
        hasShadow = false
        ignoresMouseEvents = true
        
        // Prevent window from being captured in screenshots
        sharingType = .none
        
        // Additional optimizations
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        disableSnapshotRestoration()
        
        // Ensure window is properly positioned on screen
        setFrameOrigin(frame.origin)
    }
    
    override var canBecomeKey: Bool {
        return false
    }
    
    override var canBecomeMain: Bool {
        return false
    }
    
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        // Ensure window stays at the correct level after frame changes
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    }
}
