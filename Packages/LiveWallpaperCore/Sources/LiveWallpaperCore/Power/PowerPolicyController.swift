import Foundation
import CoreGraphics

/// Manages power-aware playback policy.
/// Determines which screens should pause/resume based on power state.
@MainActor
public final class PowerPolicyController {
    /// Screens paused by power management (not manually by user)
    public private(set) var screensPausedByPowerManagement: Set<CGDirectDisplayID> = []

    /// Screens paused by full-screen app detection
    public private(set) var screensPausedByFullScreen: Set<CGDirectDisplayID> = []

    public private(set) var screensPausedByLockScreen: Set<CGDirectDisplayID> = []

    public init() {}

    public func markPausedByPower(_ screenID: CGDirectDisplayID) {
        screensPausedByPowerManagement.insert(screenID)
    }

    public func markResumedFromPower(_ screenID: CGDirectDisplayID) {
        screensPausedByPowerManagement.remove(screenID)
    }

    public func markPausedByFullScreen(_ screenID: CGDirectDisplayID) {
        screensPausedByFullScreen.insert(screenID)
    }

    public func markResumedFromFullScreen(_ screenID: CGDirectDisplayID) {
        screensPausedByFullScreen.remove(screenID)
    }

    public func markPausedByLockScreen(_ screenID: CGDirectDisplayID) {
        screensPausedByLockScreen.insert(screenID)
    }

    public func markResumedFromLockScreen(_ screenID: CGDirectDisplayID) {
        screensPausedByLockScreen.remove(screenID)
    }

    public func clearTracking(for screenID: CGDirectDisplayID) {
        screensPausedByPowerManagement.remove(screenID)
        screensPausedByFullScreen.remove(screenID)
        screensPausedByLockScreen.remove(screenID)
    }

    public func cleanUpStaleEntries(currentScreenIDs: Set<CGDirectDisplayID>) {
        screensPausedByPowerManagement = screensPausedByPowerManagement.intersection(currentScreenIDs)
        screensPausedByFullScreen = screensPausedByFullScreen.intersection(currentScreenIDs)
        screensPausedByLockScreen = screensPausedByLockScreen.intersection(currentScreenIDs)
    }

    public func wasPausedByPower(_ screenID: CGDirectDisplayID) -> Bool {
        screensPausedByPowerManagement.contains(screenID)
    }

    public func wasPausedByFullScreen(_ screenID: CGDirectDisplayID) -> Bool {
        screensPausedByFullScreen.contains(screenID)
    }

    public func wasPausedByLockScreen(_ screenID: CGDirectDisplayID) -> Bool {
        screensPausedByLockScreen.contains(screenID)
    }
}
