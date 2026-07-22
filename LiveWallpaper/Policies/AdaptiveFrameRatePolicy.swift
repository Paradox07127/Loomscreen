import Foundation

/// Decides when a scene should use its lower-power frame-rate profile.
enum AdaptiveFrameRatePolicy {
    /// Start throttling once a display is at least this occluded by other
    /// windows (union area). Below the `pauseOnWindowOcclusion` 0.85 cutoff so
    /// it fills the "mostly covered but still playing" band.
    static let occlusionEnterThreshold = 0.5
    /// Stop throttling only after occlusion drops back below this — the gap
    /// from `occlusionEnterThreshold` is hysteresis so windows hovering around
    /// half-coverage don't flap the frame rate.
    static let occlusionExitThreshold = 0.4

    /// The caller must latch only the occlusion result so battery transitions do not bypass hysteresis.
    static func shouldThrottleForOcclusion(
        occlusionFraction: Double,
        currentlyThrottled: Bool
    ) -> Bool {
        let threshold = currentlyThrottled ? occlusionExitThreshold : occlusionEnterThreshold
        return occlusionFraction >= threshold
    }

    /// Combines the latched occlusion decision with the battery policy.
    static func shouldThrottle(
        enabled: Bool,
        occlusionThrottled: Bool,
        onBattery: Bool,
        pausesOnBattery: Bool
    ) -> Bool {
        guard enabled else { return false }
        return occlusionThrottled || (onBattery && !pausesOnBattery)
    }
}
