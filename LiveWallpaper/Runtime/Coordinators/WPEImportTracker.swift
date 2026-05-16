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
/// Carved out of `ScreenManager` so the import orchestration can stay readable
/// and the two dictionaries don't have to live as ad-hoc state on the manager.
/// Marked `@Observable` so SwiftUI views reading the error through
/// `ScreenManager.wpeImportError(for:)` re-render when a record/clear happens
/// — the original dict was on `@Observable ScreenManager` and we must keep
/// that invalidation flow. The generation counter stays
/// `@ObservationIgnored` because it is internal concurrency bookkeeping and
/// no UI reads it.
@MainActor
@Observable
final class WPEImportTracker {
    private var lastErrors: [CGDirectDisplayID: AppError] = [:]

    @ObservationIgnored private var generations: [CGDirectDisplayID: Int] = [:]

    func error(for screenID: CGDirectDisplayID) -> AppError? {
        lastErrors[screenID]
    }

    func recordError(_ error: AppError, for screenID: CGDirectDisplayID) {
        lastErrors[screenID] = error
    }

    func clearError(for screenID: CGDirectDisplayID) {
        lastErrors.removeValue(forKey: screenID)
    }

    /// Returns the new generation. Callers compare against this value via
    /// `isCurrentGeneration(_:for:)` after any async hop to ensure their
    /// continuation still represents the most recent user intent.
    func bumpGeneration(for screenID: CGDirectDisplayID) -> Int {
        let next = (generations[screenID] ?? 0) &+ 1
        generations[screenID] = next
        return next
    }

    func isCurrentGeneration(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool {
        generations[screenID] == generation
    }
}
#endif
