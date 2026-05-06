import CoreGraphics
import Foundation

/// Reports per-display occlusion by full-screen apps so wallpapers can suspend.
@MainActor
protocol FullScreenDetecting: AnyObject {
    var hiddenScreens: [CGDirectDisplayID: Bool] { get }
    func isDesktopHidden(for screenID: CGDirectDisplayID) -> Bool
    func checkNow()
    func setFallbackPollingEnabled(_ enabled: Bool)
}

extension FullScreenDetector: FullScreenDetecting {}
