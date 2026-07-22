#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPE download archive reclaim selection")
struct WPEDownloadArchiveReclaimerTests {
    private func makeContentRoot(
        _ items: [(id: String, bytes: Int)]
    ) throws -> (root: URL, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-\(UUID().uuidString)", isDirectory: true)
        let root = tempRoot.appendingPathComponent("431960", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for item in items {
            let dir = root.appendingPathComponent(item.id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: item.bytes).write(to: dir.appendingPathComponent("scene.pkg"))
        }
        return (root, tempRoot)
    }

    @Test("Sums only the .pkg of cached, present ids")
    func sumsCachedPresentArchives() throws {
        let (root, tempRoot) = try makeContentRoot([("111", 1000), ("222", 2000), ("333", 4000)])
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let reclaimer = WPEDownloadArchiveReclaimer(contentRoot: root)
        #expect(reclaimer.reclaimableBytes(cachedIDs: ["111", "222", "444"]) == 3000)
    }

    @Test("An id whose folder has no scene.pkg contributes nothing")
    func ignoresFoldersWithoutArchive() throws {
        let (root, tempRoot) = try makeContentRoot([("111", 1000)])
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("222", isDirectory: true), withIntermediateDirectories: true)
        let reclaimer = WPEDownloadArchiveReclaimer(contentRoot: root)
        #expect(reclaimer.reclaimableBytes(cachedIDs: ["111", "222"]) == 1000)
    }

    @Test("Escape-capable ids are rejected, never resolved against the tree")
    func rejectsUnsafeIDs() throws {
        let (root, tempRoot) = try makeContentRoot([("111", 1000)])
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let reclaimer = WPEDownloadArchiveReclaimer(contentRoot: root)
        #expect(reclaimer.reclaimableBytes(cachedIDs: ["..", "../111", "a/b", ""]) == 0)
    }

    @Test("A symlinked id folder escaping the content root is not a candidate")
    func rejectsSymlinkEscape() throws {
        let (root, tempRoot) = try makeContentRoot([("111", 1000)])
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 9999).write(to: outside.appendingPathComponent("scene.pkg"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("999", isDirectory: true), withDestinationURL: outside)

        let reclaimer = WPEDownloadArchiveReclaimer(contentRoot: root)
        #expect(reclaimer.reclaimableBytes(cachedIDs: ["999"]) == 0)
    }

    @Test("A symlinked id folder pointing at a sibling item is not a candidate")
    func rejectsSymlinkedSiblingIDFolder() throws {
        let (root, tempRoot) = try makeContentRoot([("111", 1000)])
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("222", isDirectory: true),
            withDestinationURL: root.appendingPathComponent("111", isDirectory: true))

        let reclaimer = WPEDownloadArchiveReclaimer(contentRoot: root)
        #expect(reclaimer.reclaimableBytes(cachedIDs: ["222"]) == 0)
    }
}
#endif
