#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

/// Behavioral contract for the `wpe-tex-video` disk cache: content-addressed
/// dedup, per-scene bucketing, orphan GC keyed to the installed library, LRU
/// eviction under a byte cap (never evicting a live/leased file), and truthful
/// on-disk accounting.
@Suite("WPEVideoTextureDiskCache")
struct WPEVideoTextureDiskCacheTests {

    private func makeCache(maxBytes: UInt64 = WPEVideoTextureDiskCache.defaultMaxBytes) -> (WPEVideoTextureDiskCache, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-tex-video-test-\(UUID().uuidString)", isDirectory: true)
        return (WPEVideoTextureDiskCache(rootURL: root, maxBytes: maxBytes), root)
    }

    @Test("Identical content under the same workshop dedups to one file")
    func dedupsIdenticalContent() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let data = Data(repeating: 7, count: 4096)
        let first = try await cache.store(data, workshopID: "111")
        let second = try await cache.store(data, workshopID: "111")

        #expect(first == second)
        let stats = await cache.stats()
        #expect(stats.fileCount == 1)
    }

    @Test("Different workshops land in separate buckets")
    func separatesByWorkshop() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let data = Data(repeating: 9, count: 2048)
        let a = try await cache.store(data, workshopID: "111")
        let b = try await cache.store(data, workshopID: "222")

        #expect(a != b)
        #expect(a.deletingLastPathComponent().lastPathComponent == "111")
        #expect(b.deletingLastPathComponent().lastPathComponent == "222")
        let stats = await cache.stats()
        #expect(stats.fileCount == 2)
    }

    @Test("Workshop-less imports land in the _unattributed bucket")
    func unattributedBucketForUnsafeID() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try await cache.store(Data(repeating: 1, count: 512), workshopID: "")
        #expect(url.deletingLastPathComponent().lastPathComponent == WPEVideoTextureDiskCache.unattributedBucket)
    }

    @Test("On-disk total tracks stored content and zeroes after purge")
    func accountingMatchesContent() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await cache.store(Data(repeating: 3, count: 8192), workshopID: "111")
        _ = try await cache.store(Data(repeating: 4, count: 8192), workshopID: "222")

        let total = await cache.totalBytesOnDisk()
        #expect(total >= 16_384, "allocated size is at least the logical bytes written")

        _ = await cache.purgeAll()
        let afterStats = await cache.stats()
        #expect(afterStats.totalBytes == 0)
        #expect(afterStats.fileCount == 0)
    }

    @Test("Orphan GC reclaims loose legacy UUID files at the cache root")
    func collectOrphansDropsLooseLegacyFiles() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }

        // Simulate the pre-refactor scratch layout: flat UUID-named .mp4s
        // dropped straight in the root with no bucket (the source of the leak).
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = (0..<3).map { _ in root.appendingPathComponent("\(UUID().uuidString).mp4") }
        for url in legacy {
            try Data(repeating: 1, count: 2048).write(to: url)
        }

        // A real, currently-installed bucket must survive the same sweep.
        let keep = try await cache.store(Data(repeating: 2, count: 2048), workshopID: "111")
        await cache.release(keep)

        let freed = await cache.collectOrphans(referencedWorkshopIDs: ["111"])

        #expect(freed >= 6144)
        for url in legacy {
            #expect(FileManager.default.fileExists(atPath: url.path) == false)
        }
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test("Orphan GC drops uninstalled buckets and keeps referenced ones")
    func collectOrphansByWorkshop() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let keep = try await cache.store(Data(repeating: 1, count: 1024), workshopID: "111")
        let drop = try await cache.store(Data(repeating: 2, count: 1024), workshopID: "222")
        let unattributed = try await cache.store(Data(repeating: 3, count: 1024), workshopID: "")
        // Release leases so GC is free to reclaim the unreferenced files.
        await cache.release(keep)
        await cache.release(drop)
        await cache.release(unattributed)

        let freed = await cache.collectOrphans(referencedWorkshopIDs: ["111"])

        #expect(freed > 0)
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(FileManager.default.fileExists(atPath: drop.path) == false)
        #expect(FileManager.default.fileExists(atPath: unattributed.path) == false)
    }

    @Test("Orphan GC never reclaims a leased (live) file")
    func collectOrphansSparesLeased() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }

        // Leased and unreferenced — still must survive because it's live.
        let live = try await cache.store(Data(repeating: 5, count: 1024), workshopID: "999")
        let freedWhileLeased = await cache.collectOrphans(referencedWorkshopIDs: [])
        #expect(freedWhileLeased == 0)
        #expect(FileManager.default.fileExists(atPath: live.path))

        // Once released, the same GC reclaims it.
        await cache.release(live)
        _ = await cache.collectOrphans(referencedWorkshopIDs: [])
        #expect(FileManager.default.fileExists(atPath: live.path) == false)
    }

    @Test("Lease counting keeps a shared file alive until every holder releases")
    func leaseCountingProtectsSharedFile() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let data = Data(repeating: 6, count: 1024)
        // Two live sources share one content-addressed file (fast reload).
        let first = try await cache.store(data, workshopID: "111")
        let second = try await cache.store(data, workshopID: "111")
        #expect(first == second)

        // One source tears down — the file must survive for the other.
        await cache.release(first)
        _ = await cache.collectOrphans(referencedWorkshopIDs: [])
        #expect(FileManager.default.fileExists(atPath: first.path))

        // Last holder releases — now it's reclaimable.
        await cache.release(second)
        _ = await cache.collectOrphans(referencedWorkshopIDs: [])
        #expect(FileManager.default.fileExists(atPath: first.path) == false)
    }

    @Test("LRU eviction drops the oldest unleased file over the cap")
    func lruEvictsOldestUnleased() async throws {
        let (cache, root) = makeCache(maxBytes: 1_500)
        defer { try? FileManager.default.removeItem(at: root) }

        let older = try await cache.store(Data(repeating: 1, count: 1_000), workshopID: "111")
        await cache.release(older)
        // Force a strictly-older mtime so LRU ordering is deterministic.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: older.path
        )

        // Writing this pushes the folder over the 1.5 KB cap → oldest evicted.
        let newer = try await cache.store(Data(repeating: 2, count: 1_000), workshopID: "111")

        #expect(FileManager.default.fileExists(atPath: older.path) == false)
        #expect(FileManager.default.fileExists(atPath: newer.path))
    }

    @Test("LRU keeps every leased file even when over the cap")
    func lruSparesLeasedOverCap() async throws {
        let (cache, root) = makeCache(maxBytes: 1_500)
        defer { try? FileManager.default.removeItem(at: root) }

        let a = try await cache.store(Data(repeating: 1, count: 1_000), workshopID: "111")
        let b = try await cache.store(Data(repeating: 2, count: 1_000), workshopID: "111")

        // Both leased and over cap → nothing is safe to evict.
        let stats = await cache.stats()
        #expect(stats.fileCount == 2)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
    }
}
#endif
