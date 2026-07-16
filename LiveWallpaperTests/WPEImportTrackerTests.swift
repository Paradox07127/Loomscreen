import Testing
import AppKit
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

    @Test("Termination invalidates every admitted and future generation")
    func terminationInvalidatesGenerations() {
        let tracker = WPEImportTracker()
        let admitted = tracker.bumpGeneration(for: screenA)

        tracker.invalidateForTermination()
        let issuedAfterTermination = tracker.bumpGeneration(for: screenB)

        #expect(tracker.isTerminated)
        #expect(!tracker.isCurrentGeneration(admitted, for: screenA))
        #expect(!tracker.isCurrentGeneration(issuedAfterTermination, for: screenB))
    }

    @Test("Delayed WPE import completion after termination has no side effects")
    func delayedImportCompletionAfterTerminationIsDropped() async {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for WPE termination test")
            return
        }
        let tracker = WPEImportTracker()
        let delayedImport = DelayedWPEImportOperation()
        let historyWrites = ChangeCounter()
        let configurationWrites = ChangeCounter()
        let sessionRestores = ChangeCounter()
        let notifications = ChangeCounter()
        var lifecycleActive = true
        let coordinator = WPEImportCoordinator(
            tracker: tracker,
            configurationStore: WallpaperConfigurationStore(),
            saveConfiguration: { _ in configurationWrites.increment() },
            restoreWallpaperSession: { _, _, _ in sessionRestores.increment() },
            importOperation: { _ in await delayedImport.call() },
            recordImport: { _ in historyWrites.increment() },
            isLifecycleActive: { lifecycleActive },
            notifyImportCompleted: { _, _, _ in notifications.increment() }
        )

        let importTask = Task {
            await coordinator.importProject(
                at: FileManager.default.temporaryDirectory,
                for: screen
            )
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !delayedImport.isWaiting, ContinuousClock.now < deadline {
            await Task.yield()
        }
        guard delayedImport.isWaiting else {
            Issue.record("Timed out waiting for delayed WPE import")
            importTask.cancel()
            return
        }

        lifecycleActive = false
        tracker.invalidateForTermination()
        delayedImport.resume(with: .ready(
            .metalShader(.waves),
            origin: WPEOrigin(
                workshopID: "termination-fixture",
                title: "Termination Fixture",
                originalType: .scene,
                sourceFolderBookmark: Data([0x01]),
                cacheRelativePath: nil,
                previewFileName: nil
            )
        ))
        let outcome = await importTask.value

        guard case .rejected = outcome else {
            Issue.record("Terminated import unexpectedly applied: \(outcome)")
            return
        }
        #expect(historyWrites.value == 0)
        #expect(configurationWrites.value == 0)
        #expect(sessionRestores.value == 0)
        #expect(notifications.value == 0)
        #expect(screen.runtimeSession == nil)
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

@MainActor
private final class DelayedWPEImportOperation {
    typealias Result = WallpaperEngineImportService.ImportResult

    private var continuation: CheckedContinuation<Result, Never>?
    var isWaiting: Bool { continuation != nil }

    func call() async -> Result {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with result: Result) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}
