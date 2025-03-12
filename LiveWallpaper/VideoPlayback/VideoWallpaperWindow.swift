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
        // Additional validation to prevent invalid frames
        guard frameRect.width > 0 && frameRect.height > 0 else {
            Logger.warning("Prevented setting invalid frame: \(frameRect)", category: .ui)
            return
        }
        
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
        // Reset to proper level and order
        level = NSWindow.Level(rawValue: Self.wallpaperWindowLevel)
        orderBack(nil)
        
        // Make sure collectionBehavior includes proper settings for desktop wallpaper
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        
        // Disable interaction with the window
        ignoresMouseEvents = true
    }
    
    // In VideoWallpaperWindow.swift
    func updateFrame(_ frame: CGRect, animate: Bool = false) {
        // Skip if frame is invalid
        guard !frame.isEmpty && frame.width > 0 && frame.height > 0 else {
            Logger.warning("Attempted to set invalid frame: \(frame)", category: .ui)
            return
        }
        
        // Skip if the frame hasn't actually changed
        if NSEqualRects(self.frame, frame) {
            return
        }
        
        // Explicitly use the entire frame including origin
        let targetFrame = frame
        
        Logger.debug("Updating window frame from \(self.frame) to \(targetFrame)", category: .ui)
        
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(targetFrame, display: true, animate: true)
            }
        } else {
            setFrame(targetFrame, display: true)
        }
        
        // Ensure window maintains correct level and ordering after frame change
        ensureProperWindowLevel()
        
        // Force layout update
        if let contentView = contentView {
            contentView.frame = NSRect(origin: .zero, size: targetFrame.size)
            contentView.needsLayout = true
        }
    }
    
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Allow the window to be positioned anywhere
        frameRect
    }
}
