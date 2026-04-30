import AppKit
import Foundation
import Observation

/// Tracks whether the LiveWallpaper console / settings window is the key
/// window so the desktop scene can drop to 1 fps while the user is
/// interacting with the app. Wallpaper windows themselves never qualify as
/// "console key" — only normal windows that the AppKit window list reports
/// are eligible.
@MainActor @Observable
final class ExclusiveRenderingCoordinator {
    private(set) var isConsoleKeyWindow: Bool = false

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
        // Compute the initial state once so the consumer sees a well-defined
        // value before the first notification fires.
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
        let nextValue = active && Self.isInteractiveConsoleKeyWindow(app.keyWindow)
        if nextValue != isConsoleKeyWindow {
            isConsoleKeyWindow = nextValue
        }
    }

    /// Wallpaper windows are tagged with a non-default level + non-resizable
    /// style mask; treat anything that looks like one as "not the console
    /// window" so the scene runtime is not throttled by its own host.
    private static func isInteractiveConsoleKeyWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window is VideoWallpaperWindow { return false }
        // Wallpaper windows live on the desktop level — anything ≤ desktopWindow
        // is by construction NOT a console-style window. Check explicitly so
        // future wallpaper window types without the dedicated subclass still
        // get filtered out.
        let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        if window.level.rawValue <= desktopLevel.rawValue { return false }
        return window.canBecomeKey
    }
}
