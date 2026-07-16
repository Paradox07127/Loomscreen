import CoreGraphics
import Testing
@testable import LiveWallpaper

@Suite("Sidebar display order")
struct SidebarDisplayOrderTests {
    @Test("Saved order takes precedence over the system order")
    func savedOrderTakesPrecedence() {
        let available = [display(1, "1:1:1"), display(2, "2:2:2"), display(3, "3:3:3")]
        let saved = [available[2], available[0], available[1]]

        #expect(SidebarDisplayOrder.orderedDisplayIDs(from: available, storedOrder: saved) == [3, 1, 2])
    }

    @Test("New displays are appended in system order")
    func newDisplaysAreAppendedInSystemOrder() {
        let available = [display(2, "2:2:2"), display(1, "1:1:1"), display(3, "3:3:3")]
        let saved = [display(1, "1:1:1")]

        #expect(SidebarDisplayOrder.orderedDisplayIDs(from: available, storedOrder: saved) == [1, 2, 3])
    }

    @Test("Known fingerprint preserves order when macOS changes a display ID")
    func fingerprintPreservesOrderAcrossDisplayIDChange() {
        let available = [display(8, "8:8:8"), display(42, "1:1:1")]
        let saved = [display(7, "1:1:1"), display(8, "8:8:8")]

        #expect(SidebarDisplayOrder.orderedDisplayIDs(from: available, storedOrder: saved) == [42, 8])
    }

    @Test("A recycled ID with another fingerprint does not inherit the old position")
    func recycledIDDoesNotMatchAnotherDisplay() {
        let available = [display(7, "new:panel"), display(8, "8:8:8")]
        let saved = [display(7, "old:panel"), display(8, "8:8:8")]

        #expect(SidebarDisplayOrder.orderedDisplayIDs(from: available, storedOrder: saved) == [8, 7])
    }

    @Test("Ambiguous duplicate fingerprints keep their relative system order")
    func ambiguousDuplicateFingerprintsKeepRelativeSystemOrder() {
        let available = [display(42, "same:panel"), display(43, "same:panel"), display(9, "unique:panel")]
        let saved = [display(7, "same:panel"), display(9, "unique:panel"), display(8, "same:panel")]

        #expect(SidebarDisplayOrder.orderedDisplayIDs(from: available, storedOrder: saved) == [9, 42, 43])
    }

    @Test("Exact IDs can still reorder panels that share a fingerprint")
    func exactIDsDisambiguateDuplicateFingerprints() {
        let available = [display(42, "same:panel"), display(43, "same:panel"), display(9, "unique:panel")]
        let saved = [display(43, "same:panel"), display(9, "unique:panel"), display(42, "same:panel")]

        #expect(SidebarDisplayOrder.orderedDisplayIDs(from: available, storedOrder: saved) == [43, 9, 42])
    }

    @Test("One remaining panel cannot be assigned to either of two stored identical panels")
    func oneRemainingDuplicateFingerprintIsStillAmbiguous() {
        let available = [display(42, "same:panel"), display(30, "unique:panel")]
        let saved = [display(7, "same:panel"), display(30, "unique:panel"), display(8, "same:panel")]

        #expect(SidebarDisplayOrder.orderedDisplayIDs(from: available, storedOrder: saved) == [30, 42])
    }

    private func display(_ id: CGDirectDisplayID, _ fingerprint: String) -> SidebarDisplayOrder.Entry {
        SidebarDisplayOrder.Entry(displayID: id, fingerprint: fingerprint)
    }
}
