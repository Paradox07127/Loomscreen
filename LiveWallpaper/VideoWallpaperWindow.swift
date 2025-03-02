import AppKit

class VideoWallpaperWindow: NSWindow {
    // MARK: - Window Level Constants
    private static let desktopWindowLevel = Int(CGWindowLevelForKey(.desktopWindow))
    private static let wallpaperWindowLevel = desktopWindowLevel - 1
    
    // MARK: - Initialization
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        configureWindow()
    }
    
    private func configureWindow() {
        // Essential window properties
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: Self.wallpaperWindowLevel)
        
        // Window behavior configuration
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hasShadow = false
        ignoresMouseEvents = true
        
        // Prevent window from being captured in screenshots and recordings
        sharingType = .none
        
        // Performance optimizations
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        disableSnapshotRestoration()
        
        // Additional security and permission settings
        setAccessibilityRole(.window)
        setAccessibilitySubrole(.unknown)
        
        // Ensure proper window stacking
        orderBack(nil)
    }
    
    // MARK: - Window Behavior
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        
        // Ensure window maintains correct level after frame changes
        level = NSWindow.Level(rawValue: Self.wallpaperWindowLevel)
    }
    
    // MARK: - Performance Optimization
    override func makeKeyAndOrderFront(_ sender: Any?) {
        // Prevent window from becoming key or front
        orderBack(nil)
    }
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Prevent keyboard shortcuts from affecting the window
        false
    }
}

// MARK: - Window Management Extensions
extension VideoWallpaperWindow {
    func ensureProperWindowLevel() {
        // Ensure window is at the correct level and position
        level = NSWindow.Level(rawValue: Self.wallpaperWindowLevel)
        orderBack(nil)
    }
    
    func updateFrame(_ frame: CGRect, animate: Bool = false) {
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
        }
    }
}

// MARK: - Space and Display Management
extension VideoWallpaperWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Allow the window to be positioned anywhere
        frameRect
    }
}
