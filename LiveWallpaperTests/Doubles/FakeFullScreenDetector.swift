import CoreGraphics
import Foundation
@testable import LiveWallpaper

@MainActor
final class FakeFullScreenDetector: FullScreenDetecting {
    private var storedHiddenScreens: [CGDirectDisplayID: Bool]

    private(set) var checkNowCallCount = 0
    private(set) var setFallbackPollingEnabledValues: [Bool] = []
    private(set) var isDesktopHiddenQueries: [CGDirectDisplayID] = []

    init(hiddenScreens: [CGDirectDisplayID: Bool] = [:]) {
        storedHiddenScreens = hiddenScreens
    }

    var hiddenScreens: [CGDirectDisplayID: Bool] {
        storedHiddenScreens
    }

    func setHiddenScreens(_ hiddenScreens: [CGDirectDisplayID: Bool]) {
        storedHiddenScreens = hiddenScreens
    }

    func isDesktopHidden(for screenID: CGDirectDisplayID) -> Bool {
        isDesktopHiddenQueries.append(screenID)
        return storedHiddenScreens[screenID] ?? false
    }

    func checkNow() {
        checkNowCallCount += 1
    }

    func setFallbackPollingEnabled(_ enabled: Bool) {
        setFallbackPollingEnabledValues.append(enabled)
    }
}
