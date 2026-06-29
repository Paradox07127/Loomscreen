import Foundation

/// Decides whether a scene should run at a reduced "background" tempo to save
/// GPU power. On Apple Silicon, GPU power is near-linear in presented frame
/// count (measured: ~5.5 mW/fps; 60→15 fps ≈ −75% GPU power), so dropping the
/// frame rate whenever the user can't really see the wallpaper is a large,
/// pixel-identical power win. This only decides the *boolean* — the renderer
/// owns the actual frame-rate math, since it knows the resolved ceiling
/// (including `.unlimited`).
enum AdaptiveFrameRatePolicy {
    /// Start throttling once a display is at least this occluded by other
    /// windows (union area). Below the `pauseOnWindowOcclusion` 0.85 cutoff so
    /// it fills the "mostly covered but still playing" band.
    static let occlusionEnterThreshold = 0.5
    /// Stop throttling only after occlusion drops back below this — the gap
    /// from `occlusionEnterThreshold` is hysteresis so windows hovering around
    /// half-coverage don't flap the frame rate.
    static let occlusionExitThreshold = 0.4

    /// Occlusion-only decision with hysteresis. The caller's latch must track
    /// *only* this result, never the battery-OR'd combined one — otherwise
    /// unplugging while ~45% covered would wrongly stay throttled on the lower
    /// exit threshold without ever crossing the 0.5 enter threshold.
    static func shouldThrottleForOcclusion(
        occlusionFraction: Double,
        currentlyThrottled: Bool
    ) -> Bool {
        let threshold = currentlyThrottled ? occlusionExitThreshold : occlusionEnterThreshold
        return occlusionFraction >= threshold
    }

    /// Combined gate. `occlusionThrottled` is the latched result of
    /// `shouldThrottleForOcclusion`. Battery only contributes when the user kept
    /// wallpapers playing on battery; if `pauseOnBattery` is on the policy
    /// engine already suspends.
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
