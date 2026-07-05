import AppKit
import LiveWallpaperCore

public final class VideoWallpaperWindow: NSWindow {
    private static let desktopWindowLevel = Int(CGWindowLevelForKey(.desktopWindow))
    private static let desktopIconWindowLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
    private static let passiveWallpaperWindowLevel = desktopWindowLevel - 1
    private static let interactiveWallpaperWindowLevel = desktopIconWindowLevel + 1
    private var allowsWallpaperMouseInteraction = false

    private var wallpaperWindowLevel: Int {
        allowsWallpaperMouseInteraction
            ? Self.interactiveWallpaperWindowLevel
            : Self.passiveWallpaperWindowLevel
    }

    public init(frame: CGRect) {
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

        canBecomeVisibleWithoutLogin = true
        disableSnapshotRestoration()

        setAccessibilityRole(.window)
        setAccessibilitySubrole(.unknown)
        orderBack(nil)
    }

    // MARK: - Window Behavior
    public override var canBecomeKey: Bool { allowsWallpaperMouseInteraction }
    public override var canBecomeMain: Bool { allowsWallpaperMouseInteraction }

    public override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard frameRect.width > 0 && frameRect.height > 0 else {
            Logger.warning("Prevented setting invalid frame: \(frameRect)", category: .ui)
            return
        }

        super.setFrame(frameRect, display: flag)
        level = NSWindow.Level(rawValue: wallpaperWindowLevel)
    }

    public override func makeKeyAndOrderFront(_ sender: Any?) {
        if allowsWallpaperMouseInteraction {
            super.makeKeyAndOrderFront(sender)
        } else {
            orderBack(nil)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        false
    }
}

// MARK: - Window Management Extensions
extension VideoWallpaperWindow {
    public func ensureProperWindowLevel() {
        level = NSWindow.Level(rawValue: wallpaperWindowLevel)
        orderBack(nil)
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        applyMouseInteractionPolicy()
    }

    public func setWallpaperMouseInteractionEnabled(_ enabled: Bool) {
        allowsWallpaperMouseInteraction = enabled
        applyMouseInteractionPolicy()
    }

    /// Display-P3 color space so the composited HDR output keeps its wider gamut.
    public func setExtendedDynamicRangeEnabled(_ enabled: Bool) {
        colorSpace = enabled ? NSColorSpace.displayP3 : nil
    }

    private func applyMouseInteractionPolicy() {
        level = NSWindow.Level(rawValue: wallpaperWindowLevel)
        ignoresMouseEvents = !allowsWallpaperMouseInteraction
        acceptsMouseMovedEvents = allowsWallpaperMouseInteraction
        if allowsWallpaperMouseInteraction {
            super.makeKeyAndOrderFront(nil)
        } else {
            orderBack(nil)
        }
    }

    public func updateFrame(_ frame: CGRect, animate: Bool = false) {
        guard !frame.isEmpty && frame.width > 0 && frame.height > 0 else {
            Logger.warning("Attempted to set invalid frame: \(frame)", category: .ui)
            return
        }

        if self.frame == frame {
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

    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
