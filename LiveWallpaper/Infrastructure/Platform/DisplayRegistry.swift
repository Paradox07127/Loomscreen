import AppKit

@MainActor
final class DisplayRegistry {
    func currentScreens() -> [Screen] {
        NSScreen.screens.map(Screen.init(nsScreen:))
    }

    func findNSScreen(for screenID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { nsScreen in
            (nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == screenID
        }
    }
}
