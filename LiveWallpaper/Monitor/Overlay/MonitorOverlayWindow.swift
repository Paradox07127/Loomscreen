import AppKit
import LiveWallpaperCore

/// A borderless, non-activating panel that floats the Monitor widget board over a single display's wallpaper.
final class MonitorOverlayWindow: NSPanel {

    /// Keeps widgets above desktop content but below application windows.
    private static let desktopLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2
    )

    init(screenFrame: NSRect, level: MonitorOverlayLevel) {
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isExcludedFromWindowsMenu = true
        isRestorable = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        apply(level: level)
        setInteractive(false)
    }

    /// Map the config z-plane to a concrete window level.
    func apply(level: MonitorOverlayLevel) {
        switch level {
        case .desktop: self.level = Self.desktopLevel
        case .front: self.level = .statusBar
        }
    }

    /// Click-through when non-interactive: events pass to the desktop icons / apps underneath.
    func setInteractive(_ interactive: Bool) {
        ignoresMouseEvents = !interactive
    }

    /// Resize to follow a display geometry change.
    func applyFrame(_ frame: NSRect) {
        setFrame(frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
