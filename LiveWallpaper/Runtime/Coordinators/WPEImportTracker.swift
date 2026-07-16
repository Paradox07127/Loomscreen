#if !LITE_BUILD
import CoreGraphics
import Foundation
import Observation

/// Per-screen bookkeeping for the Wallpaper Engine import flow:
///   - last-known import error (so the Scene tab can show "Apply Failed")
///   - monotonic generation counter (so a freshly-issued import wins over
///     an in-flight one when the user double-clicks history entries on the
///     same display)
///
/// `@Observable` so SwiftUI views reading the error via
/// `ScreenManager.wpeImportError(for:)` re-render on record/clear — preserves
/// the invalidation flow from when the dict lived on `@Observable ScreenManager`.
/// The generation counter is `@ObservationIgnored` (internal concurrency
/// bookkeeping, no UI reads it).
@MainActor
@Observable
final class WPEImportTracker {
    private var lastErrors: [CGDirectDisplayID: AppError] = [:]

    @ObservationIgnored private var generations: [CGDirectDisplayID: Int] = [:]
    /// One-way process-lifetime latch. It makes every generation stale at once,
    /// including imports for screen IDs that were not present in the manager's
    /// final screen snapshot.
    @ObservationIgnored private(set) var isTerminated = false

    func error(for screenID: CGDirectDisplayID) -> AppError? {
        lastErrors[screenID]
    }

    func recordError(_ error: AppError, for screenID: CGDirectDisplayID) {
        guard !isTerminated else { return }
        lastErrors[screenID] = error
    }

    func clearError(for screenID: CGDirectDisplayID) {
        guard !isTerminated else { return }
        lastErrors.removeValue(forKey: screenID)
    }

    func bumpGeneration(for screenID: CGDirectDisplayID) -> Int {
        let next = (generations[screenID] ?? 0) &+ 1
        generations[screenID] = next
        return next
    }

    func isCurrentGeneration(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool {
        !isTerminated && generations[screenID] == generation
    }

    /// Invalidates every admitted import and permanently rejects later applies.
    /// The lifecycle bit (rather than iterating only known display IDs) is the
    /// authority, so an import finishing for a just-unplugged screen is stale too.
    func invalidateForTermination() {
        guard !isTerminated else { return }
        isTerminated = true
        generations.removeAll()
    }
}
#endif
