import AppKit
import Foundation
import Observation

/// Tracks whether the LiveWallpaper console / settings window is the key
/// window so the desktop scene can drop to 1 fps while the user is
/// interacting with the app. Wallpaper windows themselves never qualify as
/// "console key" — only normal windows that the AppKit window list reports
/// are eligible.
///
/// `consoleKeyScreenID` exposes which physical display currently hosts that
/// key window so callers can throttle ONLY the occluded scene instead of
/// throttling every screen at once (multi-display: settings on screen 1,
/// scene fully visible on screen 2 — the user can still see it).
@MainActor @Observable
final class ExclusiveRenderingCoordinator {
    private(set) var isConsoleKeyWindow: Bool = false
    private(set) var consoleKeyScreenID: CGDirectDisplayID?

    private var observers: [NSObjectProtocol] = []
    private let center = NotificationCenter.default
    private(set) var isRunning = false

    // No deinit cleanup: callers explicitly invoke `stop()` (mirrors
    // `WallpaperAutomationCoordinator.stop()` and other ScreenManager-owned
    // observers). Adding a deinit here would force isolation hops and pull
    // a non-Sendable observer list across actors.

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeScreenNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshFromCurrentState()
                }
            }
            observers.append(observer)
        }
        refreshFromCurrentState()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    private func refreshFromCurrentState() {
        let app = NSApplication.shared
        let active = app.isActive
        let keyWindow = app.keyWindow
        let nextValue = active && Self.isInteractiveConsoleKeyWindow(keyWindow)
        let nextScreenID: CGDirectDisplayID? = nextValue
            ? keyWindow?.screen.flatMap(Self.screenID(of:))
            : nil
        if nextValue != isConsoleKeyWindow {
            isConsoleKeyWindow = nextValue
        }
        if nextScreenID != consoleKeyScreenID {
            consoleKeyScreenID = nextScreenID
        }
    }

    private static func screenID(of nsScreen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (nsScreen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    /// Wallpaper windows are tagged with a non-default level + non-resizable style mask; treat anything that looks like one as "not the console window" so the scene runtime is not throttled by its own host.
    private static func isInteractiveConsoleKeyWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window is VideoWallpaperWindow { return false }
        let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        if window.level.rawValue <= desktopLevel.rawValue { return false }
        return window.canBecomeKey
    }
}
