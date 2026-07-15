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

    private func display(_ id: CGDirectDisplayID, _ fingerprint: String) -> SidebarDisplayOrder.Entry {
        SidebarDisplayOrder.Entry(displayID: id, fingerprint: fingerprint)
    }
}
