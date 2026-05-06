import AppKit

/// Enumerates connected displays and resolves screen identity for the wallpaper layer.
@MainActor
protocol DisplayRegistering: AnyObject {
    func currentScreens() -> [Screen]
    func findNSScreen(for screenID: CGDirectDisplayID) -> NSScreen?
}

extension DisplayRegistry: DisplayRegistering {}
