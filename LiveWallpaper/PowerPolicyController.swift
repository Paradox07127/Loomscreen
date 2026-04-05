import Foundation
import CoreGraphics

/// Manages power-aware playback policy.
/// Determines which screens should pause/resume based on power state.
@MainActor
final class PowerPolicyController {
    /// Screens paused by power management (not manually by user)
    private(set) var screensPausedByPowerManagement: Set<CGDirectDisplayID> = []

    /// Screens paused by full-screen app detection
    private(set) var screensPausedByFullScreen: Set<CGDirectDisplayID> = []

    func markPausedByPower(_ screenID: CGDirectDisplayID) {
        screensPausedByPowerManagement.insert(screenID)
    }

    func markResumedFromPower(_ screenID: CGDirectDisplayID) {
        screensPausedByPowerManagement.remove(screenID)
    }

    func markPausedByFullScreen(_ screenID: CGDirectDisplayID) {
        screensPausedByFullScreen.insert(screenID)
    }

    func markResumedFromFullScreen(_ screenID: CGDirectDisplayID) {
        screensPausedByFullScreen.remove(screenID)
    }

    func clearTracking(for screenID: CGDirectDisplayID) {
        screensPausedByPowerManagement.remove(screenID)
        screensPausedByFullScreen.remove(screenID)
    }

    func cleanUpStaleEntries(currentScreenIDs: Set<CGDirectDisplayID>) {
        screensPausedByPowerManagement = screensPausedByPowerManagement.intersection(currentScreenIDs)
        screensPausedByFullScreen = screensPausedByFullScreen.intersection(currentScreenIDs)
    }

    func wasPausedByPower(_ screenID: CGDirectDisplayID) -> Bool {
        screensPausedByPowerManagement.contains(screenID)
    }

    func wasPausedByFullScreen(_ screenID: CGDirectDisplayID) -> Bool {
        screensPausedByFullScreen.contains(screenID)
    }
}
