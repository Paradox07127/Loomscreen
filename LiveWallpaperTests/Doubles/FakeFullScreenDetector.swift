import CoreGraphics
import Foundation
@testable import LiveWallpaper

@MainActor
final class FakeFullScreenDetector: FullScreenDetecting {
    private var storedHiddenScreens: [CGDirectDisplayID: Bool]
    private var storedOccludedScreens: [CGDirectDisplayID: Bool]
    private var storedOcclusionFractions: [CGDirectDisplayID: CGFloat]

    private(set) var checkNowCallCount = 0
    private(set) var setFallbackPollingEnabledValues: [Bool] = []
    private(set) var isDesktopHiddenQueries: [CGDirectDisplayID] = []

    init(
        hiddenScreens: [CGDirectDisplayID: Bool] = [:],
        occludedScreens: [CGDirectDisplayID: Bool] = [:],
        occlusionFractions: [CGDirectDisplayID: CGFloat] = [:]
    ) {
        storedHiddenScreens = hiddenScreens
        storedOccludedScreens = occludedScreens
        storedOcclusionFractions = occlusionFractions
    }

    var hiddenScreens: [CGDirectDisplayID: Bool] {
        storedHiddenScreens
    }

    var occludedScreens: [CGDirectDisplayID: Bool] {
        storedOccludedScreens
    }

    var occlusionFractions: [CGDirectDisplayID: CGFloat] {
        storedOcclusionFractions
    }

    func setHiddenScreens(_ hiddenScreens: [CGDirectDisplayID: Bool]) {
        storedHiddenScreens = hiddenScreens
    }

    func setOccludedScreens(_ occludedScreens: [CGDirectDisplayID: Bool]) {
        storedOccludedScreens = occludedScreens
    }

    func setOcclusionFractions(_ occlusionFractions: [CGDirectDisplayID: CGFloat]) {
        storedOcclusionFractions = occlusionFractions
    }

    func isDesktopHidden(for screenID: CGDirectDisplayID) -> Bool {
        isDesktopHiddenQueries.append(screenID)
        return storedHiddenScreens[screenID] ?? false
    }

    func isDesktopOccluded(for screenID: CGDirectDisplayID) -> Bool {
        storedOccludedScreens[screenID] ?? false
    }

    func occlusionFraction(for screenID: CGDirectDisplayID) -> Double {
        Double(storedOcclusionFractions[screenID] ?? 0)
    }

    func checkNow() {
        checkNowCallCount += 1
    }

    func setFallbackPollingEnabled(_ enabled: Bool) {
        setFallbackPollingEnabledValues.append(enabled)
    }
}
