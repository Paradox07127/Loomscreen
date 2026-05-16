import AppKit
import Combine

/// Per-screen Combine subscription + fallback Task pair that the wallpaper
/// pipeline uses to wait for `AVPlayer` to report a real frame rate before
/// applying frame-rate-sensitive effects. Owned exclusively by
/// `PlaybackTransitionRegistry`. Intentionally not actor-isolated because
/// the registry's MainActor isolation already serialises access, and the
/// nonisolated cancellation lets `deinit` clean up safely.
public final class AssetReadinessWork {
    public var frameRateSubscription: AnyCancellable?
    public var fallbackTask: Task<Void, Never>?

    public init() {}

    public func cancel() {
        frameRateSubscription?.cancel()
        frameRateSubscription = nil
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    deinit {
        cancel()
    }
}

/// Tracks per-screen async video transitions so stale completions get
/// dropped, and owns the per-screen asset-readiness work used by
/// `applyConfigurationWhenAssetReady`. Extracted from `ScreenManager` as
/// the first step of Week 4 Task 4.5 PlaybackCoordinator extraction —
/// the goal is to validate the extraction pattern (handing one piece of
/// state at a time to a coordinator) on a low-risk surface before tackling
/// the full playback API surface.
@MainActor
public final class PlaybackTransitionRegistry {
    private var generationByScreen: [CGDirectDisplayID: Int] = [:]
    private var assetReadinessByScreen: [CGDirectDisplayID: AssetReadinessWork] = [:]

    public init() {}

    @discardableResult
    public func bumpTransition(for screenID: CGDirectDisplayID) -> Int {
        let next = (generationByScreen[screenID] ?? 0) &+ 1
        generationByScreen[screenID] = next
        return next
    }

    public func isCurrentTransition(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool {
        generationByScreen[screenID] == generation
    }

    public func cancelAssetReadiness(for screenID: CGDirectDisplayID) {
        assetReadinessByScreen[screenID]?.cancel()
        assetReadinessByScreen[screenID] = nil
    }

    /// Replaces the screen's pending asset-readiness work, cancelling any
    /// in-flight work first. Returns the freshly stored value so callers can
    /// hold a reference for `clearAssetReadinessIfMatch`.
    @discardableResult
    public func setAssetReadiness(_ work: AssetReadinessWork, for screenID: CGDirectDisplayID) -> AssetReadinessWork {
        assetReadinessByScreen[screenID]?.cancel()
        assetReadinessByScreen[screenID] = work
        return work
    }

    /// Used when an asset-readiness callback finishes naturally — only
    /// removes the slot if the same work instance is still installed (a
    /// later transition may have replaced it).
    public func clearAssetReadinessIfMatch(_ work: AssetReadinessWork, for screenID: CGDirectDisplayID) {
        if assetReadinessByScreen[screenID] === work {
            assetReadinessByScreen[screenID] = nil
        }
    }
}
