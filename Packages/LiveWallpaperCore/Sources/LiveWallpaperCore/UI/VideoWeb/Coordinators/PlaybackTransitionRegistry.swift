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
/// `applyConfigurationWhenAssetReady`. Extracted from `ScreenManager`.
@MainActor
public final class PlaybackTransitionRegistry {
    private var generationByScreen: [CGDirectDisplayID: Int] = [:]
    private var assetReadinessByScreen: [CGDirectDisplayID: AssetReadinessWork] = [:]
    /// Per-screen "validate this URL is playable" Task started in
    /// `PlaybackCoordinator.setVideo`. Stored here so that `bumpTransition`
    /// (called when the user picks a different video) can cancel the
    /// previous validation before it finishes — otherwise the stale Task
    /// keeps the security scope open and the `AVAsset` alive for several
    /// seconds past the point where the user has already moved on.
    private var validationTaskByScreen: [CGDirectDisplayID: Task<Void, Never>] = [:]

    public init() {}

    @discardableResult
    public func bumpTransition(for screenID: CGDirectDisplayID) -> Int {
        validationTaskByScreen[screenID]?.cancel()
        validationTaskByScreen[screenID] = nil
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

    @discardableResult
    public func setAssetReadiness(_ work: AssetReadinessWork, for screenID: CGDirectDisplayID) -> AssetReadinessWork {
        assetReadinessByScreen[screenID]?.cancel()
        assetReadinessByScreen[screenID] = work
        return work
    }

    /// Only removes the slot if the same work instance is still installed; a later transition may have replaced it.
    public func clearAssetReadinessIfMatch(_ work: AssetReadinessWork, for screenID: CGDirectDisplayID) {
        if assetReadinessByScreen[screenID] === work {
            assetReadinessByScreen[screenID] = nil
        }
    }

    /// Installs the validation Task for a screen, cancelling any previously
    /// in-flight validation for the same screen first. Call this immediately
    /// after creating the Task so a rapid bump doesn't slip past it.
    public func setValidationTask(_ task: Task<Void, Never>, for screenID: CGDirectDisplayID) {
        validationTaskByScreen[screenID]?.cancel()
        validationTaskByScreen[screenID] = task
    }
}
