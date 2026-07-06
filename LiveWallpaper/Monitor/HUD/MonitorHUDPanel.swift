import AppKit
import SwiftUI

/// Borderless, non-activating floating panel that hosts the fleet HUD capsule
/// above every space and full-screen app. Sizes itself to the SwiftUI content
/// and persists a user-dragged origin so the capsule stays where the user put it.
///
/// Not focus-stealing: `.nonactivatingPanel` + `hidesOnDeactivate = false` keep
/// the panel visible and click-through-friendly while the user works elsewhere.
final class MonitorHUDPanel: NSPanel {

    /// Persisted bottom-left origin (screen coordinates). Absent until the user
    /// drags the capsule the first time.
    private static let originXKey = "monitor.hud.originX"
    private static let originYKey = "monitor.hud.originY"
    /// Gap from the main screen's visible bottom-right corner for the default
    /// placement.
    private static let defaultMargin: CGFloat = 24

    private let defaults: UserDefaults
    /// Guards the auto-reposition-on-resize from clobbering a user drag: once the
    /// user moves the panel we stop pinning it to the default corner.
    private var hasUserPlacement: Bool

    init(rootView: some View, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasUserPlacement =
            defaults.object(forKey: Self.originXKey) != nil &&
            defaults.object(forKey: Self.originYKey) != nil

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isMovable = true

        // Transparent, titleless glass — the SwiftUI capsule paints its own
        // vibrancy + rounded shape, so the window itself must not draw chrome.
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Keep the rounded capsule's corners transparent (no square backing).
        contentView?.wantsLayer = true

        // Don't participate in window cycling / restoration; it's an accessory.
        isExcludedFromWindowsMenu = true
        isRestorable = false
        animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: AnyView(rootView.appLanguageScoped()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Let the capsule size the window instead of the reverse.
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = [.preferredContentSize]
        }
        contentView = hosting

        observeScreenChanges()
    }

    // MARK: - Placement

    /// Places the panel at its persisted origin (validated on-screen) or the
    /// default bottom-right corner of the main screen. Called after the content
    /// has laid out so the frame size is known.
    func applyInitialPlacement() {
        layoutIfNeeded()
        let size = frame.size

        if hasUserPlacement,
           let restored = restoredOrigin(for: size) {
            setFrameOrigin(restored)
        } else {
            setFrameOrigin(defaultOrigin(for: size))
        }
    }

    private func restoredOrigin(for size: NSSize) -> NSPoint? {
        guard
            defaults.object(forKey: Self.originXKey) != nil,
            defaults.object(forKey: Self.originYKey) != nil
        else { return nil }
        let point = NSPoint(
            x: CGFloat(defaults.double(forKey: Self.originXKey)),
            y: CGFloat(defaults.double(forKey: Self.originYKey))
        )
        let candidate = NSRect(origin: point, size: size)
        // Reject an off-screen origin (display reconfig / unplugged monitor) and
        // fall back to the default corner rather than stranding the capsule.
        guard Self.isMostlyOnScreen(candidate) else { return nil }
        return point
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: visible.maxX - size.width - Self.defaultMargin,
            y: visible.minY + Self.defaultMargin
        )
    }

    private static func isMostlyOnScreen(_ rect: NSRect) -> Bool {
        for screen in NSScreen.screens {
            let intersection = screen.visibleFrame.intersection(rect)
            let visibleArea = intersection.width * intersection.height
            let total = rect.width * rect.height
            if total > 0, visibleArea / total >= 0.5 { return true }
        }
        return false
    }

    // MARK: - Drag persistence

    /// Called by the controller's `windowDidMove` delegate after a user drag so
    /// the origin restores next launch and stops the default-corner auto-pinning.
    func persistCurrentOrigin() {
        let origin = frame.origin
        defaults.set(Double(origin.x), forKey: Self.originXKey)
        defaults.set(Double(origin.y), forKey: Self.originYKey)
        hasUserPlacement = true
    }

    // MARK: - Screen changes

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        // Re-validate: if the persisted/default origin is now off-screen (a
        // display was removed), snap back onto a live screen.
        let candidate = frame
        if !Self.isMostlyOnScreen(candidate) {
            setFrameOrigin(defaultOrigin(for: frame.size))
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Non-activating behaviour

    /// Borderless panels return false by default; allow key so the Focus button
    /// and hover work, but the non-activating style still won't steal app focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
