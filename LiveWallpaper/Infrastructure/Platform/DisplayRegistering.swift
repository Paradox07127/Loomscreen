import AppKit

@MainActor
protocol DisplayRegistering: AnyObject {
    func currentScreens() -> [Screen]
    func findNSScreen(for screenID: CGDirectDisplayID) -> NSScreen?
}

extension DisplayRegistry: DisplayRegistering {}
