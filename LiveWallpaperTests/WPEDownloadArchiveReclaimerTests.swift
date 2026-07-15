#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

/// Locks the disk-reclaim selection logic: only the source `scene.pkg` of an
/// already-cached, escape-safe id inside the content root is ever a candidate.
/// Exercises `reclaimableBytes` (side-effect-free) rather than `reclaim`, which
/// shares the same `sourceArchiveURL` resolver but moves files to the Trash.
@Suite("WPE download archive reclaim selection")
struct WPEDownloadArchiveReclaimerTests {
    /// Returns the `431960` content root (the name the reclaimer resolves against)
    /// plus the disposable temp dir holding it, which callers `defer`-remove.
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
        // 444 isn't on disk; 333 isn't in the cached set → neither counts.
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
        // A real archive parked OUTSIDE the content root.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 9999).write(to: outside.appendingPathComponent("scene.pkg"))
        // …reached only via a symlinked id folder inside the content root.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("999", isDirectory: true), withDestinationURL: outside)

        let reclaimer = WPEDownloadArchiveReclaimer(contentRoot: root)
        #expect(reclaimer.reclaimableBytes(cachedIDs: ["999"]) == 0)
    }

    @Test("A symlinked id folder pointing at a sibling item is not a candidate")
    func rejectsSymlinkedSiblingIDFolder() throws {
        // "111" is a real cached item; "222" is a symlink to 111's folder. A
        // naive contains-in-root check would resolve 222/scene.pkg back into the
        // tree and trash 111's archive — the resolver must refuse the symlink.
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
