import AppKit

class VideoWallpaperWindow: NSWindow {
    private static let desktopWindowLevel = Int(CGWindowLevelForKey(.desktopWindow))
    private static let desktopIconWindowLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
    private static let passiveWallpaperWindowLevel = desktopWindowLevel - 1
    private static let interactiveWallpaperWindowLevel = desktopIconWindowLevel - 1
    private var allowsWallpaperMouseInteraction = false

    private var wallpaperWindowLevel: Int {
        allowsWallpaperMouseInteraction
            ? Self.interactiveWallpaperWindowLevel
            : Self.passiveWallpaperWindowLevel
    }

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
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: wallpaperWindowLevel)

        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hasShadow = false
        applyMouseInteractionPolicy()
        sharingType = .none

        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        disableSnapshotRestoration()

        setAccessibilityRole(.window)
        setAccessibilitySubrole(.unknown)
        orderBack(nil)
    }
    
    // MARK: - Window Behavior
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard frameRect.width > 0 && frameRect.height > 0 else {
            Logger.warning("Prevented setting invalid frame: \(frameRect)", category: .ui)
            return
        }
        
        super.setFrame(frameRect, display: flag)
        level = NSWindow.Level(rawValue: wallpaperWindowLevel)
    }
    
    override func makeKeyAndOrderFront(_ sender: Any?) {
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
        level = NSWindow.Level(rawValue: wallpaperWindowLevel)
        orderBack(nil)
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        applyMouseInteractionPolicy()
    }

    func setWallpaperMouseInteractionEnabled(_ enabled: Bool) {
        allowsWallpaperMouseInteraction = enabled
        applyMouseInteractionPolicy()
    }

    private func applyMouseInteractionPolicy() {
        level = NSWindow.Level(rawValue: wallpaperWindowLevel)
        ignoresMouseEvents = !allowsWallpaperMouseInteraction
        acceptsMouseMovedEvents = allowsWallpaperMouseInteraction
    }

    func updateFrame(_ frame: CGRect, animate: Bool = false) {
        guard !frame.isEmpty && frame.width > 0 && frame.height > 0 else {
            Logger.warning("Attempted to set invalid frame: \(frame)", category: .ui)
            return
        }
        
        if NSEqualRects(self.frame, frame) {
            return
        }

        Logger.debug("Updating window frame from \(self.frame) to \(frame)", category: .ui)
        
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(frame, display: true, animate: true)
            }
        } else {
            setFrame(frame, display: true)
        }

        ensureProperWindowLevel()

        if let contentView = contentView {
            contentView.frame = NSRect(origin: .zero, size: frame.size)
            contentView.needsLayout = true
        }
    }
    
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
