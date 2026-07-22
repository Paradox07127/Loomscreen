import Foundation
import Testing
@testable import LiveWallpaper

/// Exercises the direct Apple Aerials path inside the signed sandboxed test host.
/// Running without host entitlements can make these checks false-green; machines without the store skip dependent cases.
struct AppleAerialsFastPathTests {

    @Test("realHomeDirectory resolves the true home, not the sandbox container")
    func realHomeIsNotContainer() {
        let real = AppleAerialsLibrary.realHomeDirectory().path
        #expect(!real.contains("/Library/Containers/"), "realHomeDirectory returned a container path: \(real)")
        #expect(real != NSHomeDirectory(), "real home must differ from the sandbox container")
    }

    @Test("Direct read + security-scoped bookmark round-trip for the standard aerials store")
    func directReadAndBookmarkWork() throws {
        guard let dir = AppleAerialsLibrary.defaultReadableDirectory() else {
            return
        }
        _ = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)

        let videos = dir.appendingPathComponent("videos", isDirectory: true)
        let movDir = FileManager.default.fileExists(atPath: videos.path(percentEncoded: false)) ? videos : dir
        guard let mov = (try? FileManager.default.contentsOfDirectory(
            at: movDir,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.pathExtension.lowercased() == "mov" }) else {
            return
        }

        let bookmark = try AppleAerialsLibrary.createReadOnlyBookmark(for: mov)
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #expect(resolved.standardizedFileURL == mov.standardizedFileURL)
        let ok = resolved.startAccessingSecurityScopedResource()
        defer { if ok { resolved.stopAccessingSecurityScopedResource() } }
        #expect(ok, "resolved security-scoped bookmark should grant access")
    }

    @Test("Fast path authorizes + populates assets with no folder-grant")
    @MainActor
    func fastPathPopulatesAssets() async {
        guard AppleAerialsLibrary.defaultReadableDirectory() != nil else {
            return
        }
        let library = AppleAerialsLibrary()
        #expect(library.isAuthorized, "standard store should authorize without a Powerbox grant")
        await library.refresh()
        #expect(library.lastScanError == nil, "scan error: \(library.lastScanError ?? "none")")
        #expect(!library.assets.isEmpty, "fast path should discover aerials from the standard store")
    }
}
