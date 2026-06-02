import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WallpaperEngineCache idempotency")
struct WallpaperEngineCacheTests {
    @Test("Cache hit when manifest fingerprint matches and payload present")
    func cacheHitWithMatchingManifest() async throws {
        let env = try TempCacheEnvironment.make(workshopID: "111")
        defer { env.cleanup() }

        let firstURL = try await env.cache.ensureExtracted(workshopID: env.workshopID, sourcePkgURL: env.pkgURL)
        let sentinel = firstURL.appendingPathComponent("hit-marker.txt")
        try Data("hit".utf8).write(to: sentinel)

        let secondURL = try await env.cache.ensureExtracted(workshopID: env.workshopID, sourcePkgURL: env.pkgURL)

        #expect(secondURL == firstURL)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("Mirrors unpacked scene directory into workshop cache and reuses unchanged mirrors")
    func mirrorsUnpackedSceneDirectoryIntoCache() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("source", isDirectory: true)
        let materials = source.appendingPathComponent("materials", isDirectory: true)
        let cacheRoot = scratch.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try Data(#"{ "camera": {}, "general": {}, "objects": [] }"#.utf8)
            .write(to: source.appendingPathComponent("scene.json"))
        try Data([0xCA, 0xFE]).write(to: materials.appendingPathComponent("layer.bin"))

        let cache = WallpaperEngineCache(rootURL: cacheRoot)
        let firstURL = try await cache.ensureMirroredDirectory(
            workshopID: "unpacked-scene",
            sourceFolderURL: source
        )
        let sentinel = firstURL.appendingPathComponent("hit-marker.txt")
        try Data("hit".utf8).write(to: sentinel)

        let secondURL = try await cache.ensureMirroredDirectory(
            workshopID: "unpacked-scene",
            sourceFolderURL: source
        )

        #expect(secondURL == firstURL)
        #expect(FileManager.default.fileExists(atPath: firstURL.appendingPathComponent("scene.json").path))
        #expect(try Data(contentsOf: firstURL.appendingPathComponent("materials/layer.bin")) == Data([0xCA, 0xFE]))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("ensureMirroredDirectory refuses to self-mirror when the source IS the cache dir (no data loss)")
    func mirrorDoesNotSelfDestructWhenSourceIsCache() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESelfMirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("source", isDirectory: true)
        let cacheRoot = scratch.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{ "camera": {}, "general": {}, "objects": [] }"#.utf8)
            .write(to: source.appendingPathComponent("scene.json"))

        let cache = WallpaperEngineCache(rootURL: cacheRoot)
        let cached = try await cache.ensureMirroredDirectory(workshopID: "self", sourceFolderURL: source)
        #expect(FileManager.default.fileExists(atPath: cached.appendingPathComponent("scene.json").path))

        // Mirroring with the cache directory itself as the source must return it
        // untouched, never removeItem(cacheURL) and wipe its own payload.
        let again = try await cache.ensureMirroredDirectory(workshopID: "self", sourceFolderURL: cached)
        #expect(again == cached)
        #expect(
            FileManager.default.fileExists(atPath: cached.appendingPathComponent("scene.json").path),
            "self-mirror must not delete the payload"
        )
    }

    @Test("Cache miss when source pkg fingerprint changes")
    func cacheMissOnFingerprintChange() async throws {
        let env = try TempCacheEnvironment.make(workshopID: "222")
        defer { env.cleanup() }

        let firstURL = try await env.cache.ensureExtracted(workshopID: env.workshopID, sourcePkgURL: env.pkgURL)
        let originalEntry = firstURL.appendingPathComponent("payload.bin")
        #expect(try Data(contentsOf: originalEntry) == Data([0x01, 0x02]))

        let secondPkgURL = env.pkgURL.deletingLastPathComponent().appendingPathComponent("scene-v2.pkg")
        let secondPkg = SyntheticPackage.makeData(entries: [
            .init(name: "fresh-payload.bin", bytes: Array(repeating: 0xAA, count: 64))
        ])
        try secondPkg.write(to: secondPkgURL)

        let secondURL = try await env.cache.ensureExtracted(workshopID: env.workshopID, sourcePkgURL: secondPkgURL)
        #expect(secondURL == firstURL, "cache directory key is workshopID, not pkg path")

        let freshEntry = secondURL.appendingPathComponent("fresh-payload.bin")
        #expect(try Data(contentsOf: freshEntry).count == 64)
        #expect(!FileManager.default.fileExists(atPath: originalEntry.path),
                "atomic re-extract must wipe stale payloads")
    }

    @Test("Cache miss when source pkg bytes change but size and mtime stay the same")
    func cacheMissOnSameSizeSameMTimeContentChange() async throws {
        let env = try TempCacheEnvironment.make(workshopID: "same-fingerprint", payload: [0x01, 0x02])
        defer { env.cleanup() }

        let firstURL = try await env.cache.ensureExtracted(workshopID: env.workshopID, sourcePkgURL: env.pkgURL)
        let payloadURL = firstURL.appendingPathComponent("payload.bin")
        #expect(try Data(contentsOf: payloadURL) == Data([0x01, 0x02]))

        let originalMTime = try #require(
            env.pkgURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let changed = SyntheticPackage.makeData(entries: [
            .init(name: "payload.bin", bytes: [0xAA, 0xBB])
        ])
        try changed.write(to: env.pkgURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: originalMTime],
            ofItemAtPath: env.pkgURL.path
        )

        let secondURL = try await env.cache.ensureExtracted(workshopID: env.workshopID, sourcePkgURL: env.pkgURL)

        #expect(secondURL == firstURL)
        #expect(try Data(contentsOf: payloadURL) == Data([0xAA, 0xBB]))
    }

    @Test("Cache miss when manifest exists but payload was deleted")
    func cacheMissWhenPayloadDeleted() async throws {
        let env = try TempCacheEnvironment.make(workshopID: "333")
        defer { env.cleanup() }

        let cacheURL = try await env.cache.ensureExtracted(workshopID: env.workshopID, sourcePkgURL: env.pkgURL)
        let entries = try FileManager.default.contentsOfDirectory(atPath: cacheURL.path)
        for entry in entries where entry != "manifest.json" {
            try FileManager.default.removeItem(at: cacheURL.appendingPathComponent(entry))
        }

        let secondURL = try await env.cache.ensureExtracted(workshopID: env.workshopID, sourcePkgURL: env.pkgURL)

        #expect(secondURL == cacheURL)
        let restored = cacheURL.appendingPathComponent("payload.bin")
        #expect(FileManager.default.fileExists(atPath: restored.path))
    }

    @Test("Invalid workshop IDs are rejected before touching disk")
    func invalidWorkshopIDRejection() async throws {
        let env = try TempCacheEnvironment.make(workshopID: "444")
        defer { env.cleanup() }

        for badID in ["", ".", "..", "/etc/passwd", "..\\foo", "foo/bar"] {
            await #expect(throws: WPECacheError.self) {
                _ = try await env.cache.ensureExtracted(workshopID: badID, sourcePkgURL: env.pkgURL)
            }
        }
    }

    @Test("Purge removes the cache directory and is safe when missing")
    func purgeRemovesCacheDirectory() async throws {
        let env = try TempCacheEnvironment.make(workshopID: "555")
        defer { env.cleanup() }

        let cacheURL = try await env.cache.ensureExtracted(workshopID: env.workshopID, sourcePkgURL: env.pkgURL)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        try await env.cache.purge(workshopID: env.workshopID)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))

        try await env.cache.purge(workshopID: env.workshopID)
    }

    @Test("stats() returns aggregated bytes and entries sorted by last-used")
    func statsAggregatesAcrossWorkshopDirectories() async throws {
        let env = try TempCacheEnvironment.make(workshopID: "stats-a")
        defer { env.cleanup() }

        _ = try await env.cache.ensureExtracted(workshopID: "alpha", sourcePkgURL: env.pkgURL)
        _ = try await env.cache.ensureExtracted(workshopID: "beta", sourcePkgURL: env.pkgURL)

        let snapshot = await env.cache.stats()

        #expect(snapshot.entries.count == 2)
        #expect(snapshot.totalBytes > 0)
        #expect(snapshot.entries.map(\.workshopID).sorted() == ["alpha", "beta"])
        for entry in snapshot.entries {
            #expect(entry.sizeBytes > 0)
            #expect(entry.lastUsed != nil)
        }
    }

    @Test("purgeAll() removes every workshop subdirectory and reports freed bytes")
    func purgeAllRemovesAllWorkshops() async throws {
        let env = try TempCacheEnvironment.make(workshopID: "purgeall")
        defer { env.cleanup() }

        _ = try await env.cache.ensureExtracted(workshopID: "one", sourcePkgURL: env.pkgURL)
        _ = try await env.cache.ensureExtracted(workshopID: "two", sourcePkgURL: env.pkgURL)
        let beforeStats = await env.cache.stats()
        #expect(beforeStats.entries.count == 2)
        #expect(beforeStats.totalBytes > 0)

        let freed = await env.cache.purgeAll()
        #expect(freed > 0)

        let afterStats = await env.cache.stats()
        #expect(afterStats.entries.isEmpty)
        #expect(afterStats.totalBytes == 0)
    }

    @Test("purgeOlderThan() only drops entries whose lastUsed predates the cutoff")
    func purgeOlderThanScopesByLastUsed() async throws {
        let env = try TempCacheEnvironment.make(workshopID: "older")
        defer { env.cleanup() }

        _ = try await env.cache.ensureExtracted(workshopID: "fresh", sourcePkgURL: env.pkgURL)
        _ = try await env.cache.ensureExtracted(workshopID: "stale", sourcePkgURL: env.pkgURL)

        let allFreed = await env.cache.purgeOlderThan(Date().addingTimeInterval(60))
        #expect(allFreed > 0)
        #expect(await env.cache.stats().entries.isEmpty)

        _ = try await env.cache.ensureExtracted(workshopID: "fresh-again", sourcePkgURL: env.pkgURL)
        let nothingFreed = await env.cache.purgeOlderThan(Date(timeIntervalSince1970: 0))
        #expect(nothingFreed == 0)
        #expect(await env.cache.stats().entries.count == 1)
    }
}

private struct TempCacheEnvironment {
    let cache: WallpaperEngineCache
    let pkgURL: URL
    let cacheRoot: URL
    let workshopID: String

    static func make(workshopID: String, payload: [UInt8] = [0x01, 0x02]) throws -> TempCacheEnvironment {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheRoot = scratch.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let pkgURL = scratch.appendingPathComponent("scene.pkg")
        let pkgData = SyntheticPackage.makeData(entries: [.init(name: "payload.bin", bytes: payload)])
        try pkgData.write(to: pkgURL)

        return TempCacheEnvironment(
            cache: WallpaperEngineCache(rootURL: cacheRoot),
            pkgURL: pkgURL,
            cacheRoot: cacheRoot,
            workshopID: workshopID
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent())
    }
}

/// Builder for a minimal `PKGV0022` archive used across cache tests.
fileprivate enum SyntheticPackage {
    struct Entry {
        let name: String
        let bytes: [UInt8]
    }

    static func makeData(entries: [Entry]) -> Data {
        var payload = Data()
        var offsets: [(name: String, offset: UInt32, size: UInt32)] = []

        for entry in entries {
            let offset = UInt32(payload.count)
            payload.append(contentsOf: entry.bytes)
            offsets.append((entry.name, offset, UInt32(entry.bytes.count)))
        }

        var data = Data()
        let magicBytes = Array("PKGV0022".utf8)
        appendU32(UInt32(magicBytes.count), to: &data)
        data.append(contentsOf: magicBytes)
        appendU32(UInt32(offsets.count), to: &data)

        for entry in offsets {
            let nameBytes = Array(entry.name.utf8)
            appendU32(UInt32(nameBytes.count), to: &data)
            data.append(contentsOf: nameBytes)
            appendU32(entry.offset, to: &data)
            appendU32(entry.size, to: &data)
        }

        data.append(payload)
        return data
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}
