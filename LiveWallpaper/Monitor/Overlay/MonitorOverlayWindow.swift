import AppKit
import LiveWallpaperCore

/// A borderless, non-activating panel that floats the Monitor widget board over a
/// single display's wallpaper. Its z-plane is switchable per the config:
///   • `.desktop` — one level above the wallpaper window (below desktop icons and
///     app windows). Click-through, so desktop icons stay clickable; a second
///     ambience layer over the video/scene/HTML wallpaper.
///   • `.front` — status-bar level, above every app window (the Fleet HUD's plane).
///
/// One panel per display; `MonitorOverlayController` owns the lifecycle and sets
/// the board host as the content view. The panel never activates the app or steals
/// key focus, and is fully click-through unless the board is being edited.
final class MonitorOverlayWindow: NSPanel {

    /// Above the wallpaper window AND desktop icons, but still below every app
    /// window — the widget board is clearly visible over whatever wallpaper the
    /// display shows (video/scene/html all sit at ≤ desktop-icon level), while the
    /// user's app windows still cover it. Click-through keeps icons usable.
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
        // Show on every Space and alongside full-screen apps; don't move with the
        // active Space or participate in ⌘` window cycling.
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

    /// Click-through when non-interactive: events pass to the desktop icons / apps
    /// underneath. Captures events only while the board is being edited (or when
    /// the board's own mouse-interaction flag is on).
    func setInteractive(_ interactive: Bool) {
        ignoresMouseEvents = !interactive
    }

    /// Resize to follow a display geometry change.
    func applyFrame(_ frame: NSRect) {
        setFrame(frame, display: true)
    }

    // Non-activating: allow key (so edit chrome/hover works) but never main, and
    // never steal app focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
