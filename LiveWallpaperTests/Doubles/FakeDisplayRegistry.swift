import AppKit
@testable import LiveWallpaper

@MainActor
final class FakeDisplayRegistry: DisplayRegistering {
    var screens: [Screen]
    var nsScreensByID: [CGDirectDisplayID: NSScreen]

    private(set) var currentScreensCallCount = 0
    private(set) var findNSScreenQueries: [CGDirectDisplayID] = []

    init(
        screens: [Screen] = [],
        nsScreensByID: [CGDirectDisplayID: NSScreen] = [:]
    ) {
        self.screens = screens
        self.nsScreensByID = nsScreensByID
    }

    func currentScreens() -> [Screen] {
        currentScreensCallCount += 1
        return screens
    }

    func findNSScreen(for screenID: CGDirectDisplayID) -> NSScreen? {
        findNSScreenQueries.append(screenID)
        if let nsScreen = nsScreensByID[screenID] {
            return nsScreen
        }
        return screens.first(where: { $0.id == screenID })?.nsScreen
    }
}
