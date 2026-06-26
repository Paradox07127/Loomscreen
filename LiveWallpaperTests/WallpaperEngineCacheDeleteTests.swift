import Foundation
import Testing
@testable import LiveWallpaper

/// `deleteFiles` permanently removes a per-workshop cache dir to reclaim disk
/// space — it must NOT use the Trash, because under App Sandbox `trashItem` on
/// a container-internal path only reaches the invisible per-container `.Trash`
/// and never frees space (the "delete leaves nothing in the Trash" bug).
@Suite("WallpaperEngineCache.deleteFiles")
struct WallpaperEngineCacheDeleteTests {

    private func makeCacheRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEDelete-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Deletes the per-workshop directory and its contents, reporting true")
    func deletesExistingDirectory() async throws {
        let root = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WallpaperEngineCache(rootURL: root)

        let itemDir = root.appendingPathComponent("12345", isDirectory: true)
        let nested = itemDir.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0xCA, 0xFE]).write(to: nested.appendingPathComponent("layer.bin"))
        #expect(FileManager.default.fileExists(atPath: itemDir.path))

        let removed = try await cache.deleteFiles(workshopID: "12345")

        #expect(removed)
        #expect(!FileManager.default.fileExists(atPath: itemDir.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Returns false (no throw) when the directory is already gone")
    func missingDirectoryIsNoOp() async throws {
        let root = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = WallpaperEngineCache(rootURL: root)

        #expect(try await cache.deleteFiles(workshopID: "67890") == false)
    }

    @Test("A second delete of the same id is a clean no-op")
    func secondDeleteIsNoOp() async throws {
        let root = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WallpaperEngineCache(rootURL: root)
        let itemDir = root.appendingPathComponent("222", isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

        #expect(try await cache.deleteFiles(workshopID: "222"))
        #expect(try await cache.deleteFiles(workshopID: "222") == false)
    }
}
