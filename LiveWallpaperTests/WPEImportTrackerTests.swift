import Testing
import Foundation
import Observation
import CoreGraphics
@testable import LiveWallpaper

/// Behavior-level tests for `WPEImportTracker`. The regression motivating
/// the `@Observable` markup: when the tracker lived as a private dict on the
/// `@Observable` `ScreenManager`, SwiftUI views reading the error via
/// `screenManager.wpeImportError(for:)` re-rendered on every record/clear.
/// After the extraction we have to keep that invalidation flow alive — these
/// tests assert it via `withObservationTracking`.
@Suite("WPEImportTracker")
@MainActor
struct WPEImportTrackerTests {
    private let screenA: CGDirectDisplayID = 1
    private let screenB: CGDirectDisplayID = 2

    @Test("Records, reads, and clears errors per screen")
    func errorRoundtrip() {
        let tracker = WPEImportTracker()
        #expect(tracker.error(for: screenA) == nil)
        tracker.recordError(.wpePackageInvalid("bad payload"), for: screenA)
        #expect(tracker.error(for: screenA) == .wpePackageInvalid("bad payload"))
        #expect(tracker.error(for: screenB) == nil)
        tracker.clearError(for: screenA)
        #expect(tracker.error(for: screenA) == nil)
    }

    @Test("recordError invalidates Observation for SwiftUI re-render")
    func recordErrorInvalidatesObservation() {
        let tracker = WPEImportTracker()
        let counter = ChangeCounter()

        // Establish a tracked read; mutate; expect the tracking closure to fire
        // exactly once (Observation contract). If the tracker were not
        // `@Observable`, the closure would never fire and SwiftUI's
        // `wpeImportError(for:)` reads in `WPESceneSection` would not refresh.
        withObservationTracking {
            _ = tracker.error(for: screenA)
        } onChange: {
            counter.increment()
        }

        #expect(counter.value == 0)
        tracker.recordError(.wpeImportFailed("disk full"), for: screenA)
        #expect(counter.value == 1)
    }

    @Test("clearError invalidates Observation for SwiftUI re-render")
    func clearErrorInvalidatesObservation() {
        let tracker = WPEImportTracker()
        tracker.recordError(.fileAccessDenied("Scene"), for: screenA)
        let counter = ChangeCounter()

        withObservationTracking {
            _ = tracker.error(for: screenA)
        } onChange: {
            counter.increment()
        }

        tracker.clearError(for: screenA)
        #expect(counter.value == 1)
    }

    @Test("Generation counter increments monotonically per screen")
    func generationMonotonic() {
        let tracker = WPEImportTracker()
        let first = tracker.bumpGeneration(for: screenA)
        let second = tracker.bumpGeneration(for: screenA)
        let third = tracker.bumpGeneration(for: screenA)
        #expect(first == 1)
        #expect(second == 2)
        #expect(third == 3)

        // Independent generation per screen
        let otherFirst = tracker.bumpGeneration(for: screenB)
        #expect(otherFirst == 1)
    }

    @Test("isCurrentGeneration only matches the latest bump")
    func generationCurrencyCheck() {
        let tracker = WPEImportTracker()
        let stale = tracker.bumpGeneration(for: screenA)
        let fresh = tracker.bumpGeneration(for: screenA)
        #expect(tracker.isCurrentGeneration(stale, for: screenA) == false)
        #expect(tracker.isCurrentGeneration(fresh, for: screenA) == true)
    }
}

/// Reference-type counter used to capture Observation callback fires from
/// `withObservationTracking { ... } onChange:`. The `onChange` block runs in
/// a non-isolated context that Swift 6 won't let us mutate a captured `var`
/// from; a `final class` with locked mutation satisfies that constraint.
private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
