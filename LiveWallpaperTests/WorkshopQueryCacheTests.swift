#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WorkshopQueryCache")
struct WorkshopQueryCacheTests {

    @Test("Cache writes, reads, sizes, and clears pages on disk")
    func cacheRoundTripsPagesOnDisk() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("workshop-query-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let cache = WorkshopQueryCache(
            directoryURL: directory,
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        let page = WorkshopQueryPage(
            items: [
                WorkshopQueryItem(
                    id: 123,
                    title: "Aurora",
                    shortDescription: "Test item",
                    creatorID: "76561190000000000",
                    creatorPersonaName: "Creator",
                    previewImageURL: URL(string: "https://steamuserimages-a.akamaihd.net/test.jpg"),
                    fileSizeBytes: 42,
                    timeUpdated: Date(timeIntervalSince1970: 9_000),
                    subscriptionCount: 7,
                    voteScore: 0.9,
                    tags: ["Scene"],
                    visibility: .public,
                    isBanned: false,
                    steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=123")!
                )
            ],
            nextCursor: "next",
            totalAvailable: 1
        )

        await cache.write(page, forKey: "test-key")

        #expect(await cache.read(forKey: "test-key") == page)
        #expect(await cache.sizeBytes() > 0)

        await cache.clear()

        #expect(await cache.read(forKey: "test-key") == nil)
        #expect(await cache.sizeBytes() == 0)
    }
}
#endif
