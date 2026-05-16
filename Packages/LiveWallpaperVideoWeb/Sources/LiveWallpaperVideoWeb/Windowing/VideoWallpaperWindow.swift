import AppKit
import LiveWallpaperCore

public class VideoWallpaperWindow: NSWindow {
    private static let desktopWindowLevel = Int(CGWindowLevelForKey(.desktopWindow))
    private static let desktopIconWindowLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
    private static let passiveWallpaperWindowLevel = desktopWindowLevel - 1
    // Plash 模式：交互态把 window 抬到桌面图标层之上。
    // 这样 macOS Sonoma 的 "Click wallpaper to reveal desktop" 手势再也拿不到点击 —
    // 该手势是派发给系统桌面壁纸 window 的，我们盖在它和图标层之上后事件被消费在自己的 window 里。
    // 代价：交互态会遮住桌面图标（与 Plash 一致）。
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
        disableSnapshotRestoration()

        setAccessibilityRole(.window)
        setAccessibilitySubrole(.unknown)
        orderBack(nil)
    }

    // MARK: - Window Behavior
    // 交互态需要成为 key window，否则 WKWebView 收不到键盘 / 焦点事件。
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
        // 非交互态：保持壁纸语义，强制排到背后。
        // 交互态：放行真正的 key window 行为。
        if allowsWallpaperMouseInteraction {
            super.makeKeyAndOrderFront(sender)
        } else {
            orderBack(nil)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Prevent keyboard shortcuts from affecting the window
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

    /// Switches the window's color space when an HDR video is loaded so the
    /// composited output preserves the wider gamut. `nil` restores the
    /// system default (sRGB-tagged) for SDR sources.
    public func setExtendedDynamicRangeEnabled(_ enabled: Bool) {
        colorSpace = enabled ? NSColorSpace.displayP3 : nil
    }

    private func applyMouseInteractionPolicy() {
        level = NSWindow.Level(rawValue: wallpaperWindowLevel)
        ignoresMouseEvents = !allowsWallpaperMouseInteraction
        acceptsMouseMovedEvents = allowsWallpaperMouseInteraction
        if allowsWallpaperMouseInteraction {
            // 抬到 desktopIcon + 1 后必须主动 makeKeyAndOrderFront，
            // 否则 window 仍处于 ordered-back 状态、点击不触发 hit-test。
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

    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
