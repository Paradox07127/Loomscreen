import Foundation
import Testing
@testable import LiveWallpaper

/// Guards the sandbox-correct behaviour behind "Connect Apple Aerials" — real-home
/// resolution and the direct-read fast path.
///
/// These run INSIDE the sandboxed host app (`TEST_HOST = LiveWallpaper.app`), so
/// they exercise the real sandbox + entitlements. Must run WITHOUT
/// `CODE_SIGNING_ALLOWED=NO` (which strips entitlements and would make the read
/// checks a false green). Machine-dependent checks self-skip when the current
/// macOS aerials store isn't present.
struct AppleAerialsFastPathTests {

    /// Regression guard for the sandbox-home bug. In the App Sandbox
    /// `NSHomeDirectory()` (and `homeDirectoryForCurrentUser`) return the container
    /// `~/Library/Containers/<id>/Data`; a path built from that does not exist, so
    /// the grant panel ignored its `directoryURL` and reopened at the last-used
    /// location. `realHomeDirectory()` must resolve the true `/Users/<name>`.
    @Test("realHomeDirectory resolves the true home, not the sandbox container")
    func realHomeIsNotContainer() {
        let real = AppleAerialsLibrary.realHomeDirectory().path
        #expect(!real.contains("/Library/Containers/"), "realHomeDirectory returned a container path: \(real)")
        // In-sandbox the container IS what NSHomeDirectory reports, so any revert to
        // it (the original bug) would make these equal — catch that.
        #expect(real != NSHomeDirectory(), "real home must differ from the sandbox container")
    }

    /// The apply path and thumbnails resolve a `.withSecurityScope` bookmark per
    /// asset, so the fast path only works if the app can (a) read Apple's folder
    /// directly and (b) mint + resolve such a bookmark for a file there. Proven
    /// end-to-end against the machine's real store.
    @Test("Direct read + security-scoped bookmark round-trip for the standard aerials store")
    func directReadAndBookmarkWork() throws {
        guard let dir = AppleAerialsLibrary.defaultReadableDirectory() else {
            return // No current-macOS aerials store on this machine — nothing to verify.
        }
        // Read access present: the directory lists without throwing.
        _ = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)

        let videos = dir.appendingPathComponent("videos", isDirectory: true)
        let movDir = FileManager.default.fileExists(atPath: videos.path(percentEncoded: false)) ? videos : dir
        guard let mov = (try? FileManager.default.contentsOfDirectory(
            at: movDir,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.pathExtension.lowercased() == "mov" }) else {
            return // Store present but empty — nothing to bookmark.
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

    /// End-to-end: a fresh library is authorized WITHOUT any panel/bookmark and a
    /// refresh discovers assets straight from the entitlement-readable store. This
    /// is the whole fast path (defaultReadableDirectory → scanPlan → scanAssets).
    @Test("Fast path authorizes + populates assets with no folder-grant")
    @MainActor
    func fastPathPopulatesAssets() async {
        guard AppleAerialsLibrary.defaultReadableDirectory() != nil else {
            return // No current-macOS aerials store on this machine.
        }
        let library = AppleAerialsLibrary()
        #expect(library.isAuthorized, "standard store should authorize without a Powerbox grant")
        await library.refresh()
        #expect(library.lastScanError == nil, "scan error: \(library.lastScanError ?? "none")")
        #expect(!library.assets.isEmpty, "fast path should discover aerials from the standard store")
    }
}
