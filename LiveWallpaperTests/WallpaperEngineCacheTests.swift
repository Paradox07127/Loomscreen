import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WallpaperEngineCache enumeration and reclaim")
struct WallpaperEngineCacheTests {
    @Test("A legacy manifest still marks a cache complete")
    func legacyManifestMarksCacheCompleted() async throws {
        let env = try TempCacheEnvironment.make()
        defer { env.cleanup() }
        try env.seed(workshopID: "with-manifest")
        try env.seed(workshopID: "no-manifest", manifest: false)

        #expect(await env.cache.listCompletedWorkshopIDs() == ["with-manifest"])
        #expect(await env.cache.listAvailableWorkshopIDs() == ["with-manifest", "no-manifest"])
    }

    @Test("Invalid workshop IDs are rejected before touching disk")
    func invalidWorkshopIDRejection() async throws {
        let env = try TempCacheEnvironment.make()
        defer { env.cleanup() }

        for badID in ["", ".", "..", "/etc/passwd", "..\\foo", "foo/bar"] {
            await #expect(throws: WPECacheError.self) {
                try await env.cache.purge(workshopID: badID)
            }
        }
    }

    @Test("Purge removes the cache directory and is safe when missing")
    func purgeRemovesCacheDirectory() async throws {
        let env = try TempCacheEnvironment.make()
        defer { env.cleanup() }
        let cacheURL = try env.seed(workshopID: "555")
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        try await env.cache.purge(workshopID: "555")
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))

        try await env.cache.purge(workshopID: "555")
    }

    @Test("stats() returns aggregated bytes and entries sorted by last-used")
    func statsAggregatesAcrossWorkshopDirectories() async throws {
        let env = try TempCacheEnvironment.make()
        defer { env.cleanup() }
        try env.seed(workshopID: "alpha")
        try env.seed(workshopID: "beta")

        let snapshot = await env.cache.stats()

        #expect(snapshot.entries.count == 2)
        #expect(snapshot.totalBytes > 0)
        #expect(snapshot.entries.map(\.workshopID).sorted() == ["alpha", "beta"])
        for entry in snapshot.entries {
            #expect(entry.sizeBytes > 0)
            #expect(entry.lastUsed != nil)
        }
    }

    @Test("stats() reads lastUsed from the manifest's extractedAt")
    func statsReadsLastUsedFromManifest() async throws {
        let env = try TempCacheEnvironment.make()
        defer { env.cleanup() }
        let extractedAt = Date(timeIntervalSince1970: 1_600_000_000)
        try env.seed(workshopID: "dated", extractedAt: extractedAt)

        let entry = try #require(await env.cache.stats().entries.first)
        #expect(entry.lastUsed == extractedAt)
    }

    @Test("purgeAll() removes every workshop subdirectory and reports freed bytes")
    func purgeAllRemovesAllWorkshops() async throws {
        let env = try TempCacheEnvironment.make()
        defer { env.cleanup() }
        try env.seed(workshopID: "one")
        try env.seed(workshopID: "two")
        let beforeStats = await env.cache.stats()
        #expect(beforeStats.entries.count == 2)
        #expect(beforeStats.totalBytes > 0)

        let freed = await env.cache.purgeAll()
        #expect(freed > 0)

        let afterStats = await env.cache.stats()
        #expect(afterStats.entries.isEmpty)
        #expect(afterStats.totalBytes == 0)
    }

    @Test("collectOrphans() drops unreferenced workshops and keeps referenced ones")
    func collectOrphansDropsUnreferenced() async throws {
        let env = try TempCacheEnvironment.make()
        defer { env.cleanup() }

        let keepURL = try env.seed(workshopID: "keep")
        let dropURL = try env.seed(workshopID: "drop")

        let freed = await env.cache.collectOrphans(keepIDs: ["keep"])

        #expect(freed > 0)
        #expect(FileManager.default.fileExists(atPath: keepURL.path), "referenced scene must survive")
        #expect(!FileManager.default.fileExists(atPath: dropURL.path), "unreferenced scene must be reclaimed")
        let remaining = await env.cache.stats().entries.map(\.workshopID)
        #expect(remaining == ["keep"])
    }

    @Test("collectOrphans() reclaims stale extraction sidecars but spares young ones")
    func collectOrphansSidecarAgeGate() async throws {
        let env = try TempCacheEnvironment.make()
        defer { env.cleanup() }
        let live = try env.seed(workshopID: "live")

        let fm = FileManager.default
        let staleSidecar = env.cacheRoot.appendingPathComponent("999.inflight", isDirectory: true)
        let youngSidecar = env.cacheRoot.appendingPathComponent("888.replaced", isDirectory: true)
        for sidecar in [staleSidecar, youngSidecar] {
            try fm.createDirectory(at: sidecar, withIntermediateDirectories: true)
            try Data([0x00, 0x01]).write(to: sidecar.appendingPathComponent("partial.bin"))
        }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: staleSidecar.path)

        _ = await env.cache.collectOrphans(keepIDs: ["live"])

        #expect(!fm.fileExists(atPath: staleSidecar.path), "stale crash sidecar must be reclaimed")
        #expect(fm.fileExists(atPath: youngSidecar.path), "young sidecar (possible live extraction) must be spared")
        #expect(fm.fileExists(atPath: live.path), "referenced scene must be untouched")
    }

    @Test("purgeOlderThan() never removes ids in the keep-set")
    func purgeOlderThanRespectsKeepSet() async throws {
        let env = try TempCacheEnvironment.make()
        defer { env.cleanup() }
        try env.seed(workshopID: "keep")
        try env.seed(workshopID: "drop")

        let freed = await env.cache.purgeOlderThan(Date().addingTimeInterval(60), keepingIDs: ["keep"])

        #expect(freed > 0)
        #expect(await env.cache.stats().entries.map(\.workshopID) == ["keep"])
    }

    @Test("collectOrphans() keeps everything when all ids are referenced and frees nothing")
    func collectOrphansNoOpWhenAllReferenced() async throws {
        let env = try TempCacheEnvironment.make()
        defer { env.cleanup() }

        try env.seed(workshopID: "one")
        try env.seed(workshopID: "two")

        let freed = await env.cache.collectOrphans(keepIDs: ["one", "two"])

        #expect(freed == 0)
        #expect(await env.cache.stats().entries.count == 2)
    }

    @Test("purgeOlderThan() only drops entries whose lastUsed predates the cutoff")
    func purgeOlderThanScopesByLastUsed() async throws {
        let env = try TempCacheEnvironment.make()
        defer { env.cleanup() }

        try env.seed(workshopID: "fresh")
        try env.seed(workshopID: "stale", extractedAt: Date(timeIntervalSince1970: 0))

        let freed = await env.cache.purgeOlderThan(Date().addingTimeInterval(-3600))

        #expect(freed > 0)
        #expect(await env.cache.stats().entries.map(\.workshopID) == ["fresh"])
    }
}

private struct TempCacheEnvironment {
    let cache: WallpaperEngineCache
    let cacheRoot: URL

    static func make() throws -> TempCacheEnvironment {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheRoot = scratch.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return TempCacheEnvironment(cache: WallpaperEngineCache(rootURL: cacheRoot), cacheRoot: cacheRoot)
    }

    @discardableResult
    func seed(
        workshopID: String,
        manifest: Bool = true,
        extractedAt: Date = Date()
    ) throws -> URL {
        let dir = cacheRoot.appendingPathComponent(workshopID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x01, 0x02]).write(to: dir.appendingPathComponent("payload.bin"))
        guard manifest else { return dir }
        let json = """
        {"extractedAt":\(extractedAt.timeIntervalSince1970),\
        "fingerprint":{"mtime":1600000000.0,"sha256":"deadbeef","size":2}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent())
    }
}
