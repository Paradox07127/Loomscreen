#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Workshop installed sort")
struct WorkshopInstalledSortTests {
    @Test("Update-available sort puts stale imports first then sorts by name")
    func updateAvailableSortGroupsStaleImportsFirst() {
        let entries = [
            makeEntry(id: "100", title: "Zebra"),
            makeEntry(id: "200", title: "Alpha"),
            makeEntry(id: "300", title: "Beta")
        ]

        let sorted = WPEInstalledLibrarySorter.sorted(
            entries,
            by: .updateAvailable,
            updatedWorkshopIDs: ["300", "200"]
        )

        #expect(sorted.map(\.origin.workshopID) == ["200", "300", "100"])
    }

    private func makeEntry(id: String, title: String) -> WPEHistoryEntry {
        WPEHistoryEntry(
            origin: WPEOrigin(
                workshopID: id,
                title: title,
                originalType: .scene,
                sourceFolderBookmark: Data(id.utf8),
                cacheRelativePath: "wpe-cache/\(id)",
                previewFileName: "preview.gif"
            ),
            importedAt: Date(timeIntervalSince1970: Double(id) ?? 0)
        )
    }
}
#endif
