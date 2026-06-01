import CoreGraphics
import Foundation
@testable import LiveWallpaper

@MainActor
final class FakeFullScreenDetector: FullScreenDetecting {
    private var storedHiddenScreens: [CGDirectDisplayID: Bool]
    private var storedOccludedScreens: [CGDirectDisplayID: Bool]

    private(set) var checkNowCallCount = 0
    private(set) var setFallbackPollingEnabledValues: [Bool] = []
    private(set) var isDesktopHiddenQueries: [CGDirectDisplayID] = []

    init(
        hiddenScreens: [CGDirectDisplayID: Bool] = [:],
        occludedScreens: [CGDirectDisplayID: Bool] = [:]
    ) {
        storedHiddenScreens = hiddenScreens
        storedOccludedScreens = occludedScreens
    }

    var hiddenScreens: [CGDirectDisplayID: Bool] {
        storedHiddenScreens
    }

    var occludedScreens: [CGDirectDisplayID: Bool] {
        storedOccludedScreens
    }

    func setHiddenScreens(_ hiddenScreens: [CGDirectDisplayID: Bool]) {
        storedHiddenScreens = hiddenScreens
    }

    func setOccludedScreens(_ occludedScreens: [CGDirectDisplayID: Bool]) {
        storedOccludedScreens = occludedScreens
    }

    func isDesktopHidden(for screenID: CGDirectDisplayID) -> Bool {
        isDesktopHiddenQueries.append(screenID)
        return storedHiddenScreens[screenID] ?? false
    }

    func isDesktopOccluded(for screenID: CGDirectDisplayID) -> Bool {
        storedOccludedScreens[screenID] ?? false
    }

    func checkNow() {
        checkNowCallCount += 1
    }

    func setFallbackPollingEnabled(_ enabled: Bool) {
        setFallbackPollingEnabledValues.append(enabled)
    }
}
