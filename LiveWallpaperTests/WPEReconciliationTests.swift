import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

@Suite("WPE reconcile + matchesBookmark contract") @MainActor
struct WPEReconciliationTests {

    // MARK: - WPEOriginReconciler

    @Test("Reconcile is a no-op when wpeOrigin is already nil")
    func reconcileNoopWhenOriginAbsent() {
        var config = makeConfiguration(activeWallpaper: .video(bookmarkData: Data([0x01])))
        config.wpeOrigin = nil
        WPEOriginReconciler().reconcile(&config, event: .userReplacedActiveWallpaper(previous: nil))
        #expect(config.wpeOrigin == nil)
    }

    @Test("Reconcile clears origin when cacheRelativePath is nil (unsupported import)")
    func reconcileClearsWhenCachePathMissing() {
        var config = makeConfiguration(activeWallpaper: .video(bookmarkData: Data([0x01])))
        config.wpeOrigin = makeOrigin(workshopID: "111", cacheRelativePath: nil)
        WPEOriginReconciler().reconcile(&config, event: .userReplacedActiveWallpaper(previous: nil))
        #expect(config.wpeOrigin == nil)
    }

    @Test("Reconcile preserves unpacked WPE web imports backed by the source folder")
    func reconcilePreservesSourceFolderWebOrigin() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-source-web-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: folder.appendingPathComponent("index.html"))

        let bookmark = try folder.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let origin = WPEOrigin(
            workshopID: "source-web",
            title: "Source Web",
            originalType: .web,
            sourceFolderBookmark: bookmark,
            cacheRelativePath: nil,
            previewFileName: "preview.gif"
        )
        var config = makeConfiguration(activeWallpaper: .html(
            source: .folder(bookmarkData: bookmark, indexFileName: "index.html"),
            config: .default
        ))
        config.wpeOrigin = origin

        WPEOriginReconciler().reconcile(&config, event: .userReplacedActiveWallpaper(previous: nil))

        #expect(config.wpeOrigin == origin)
    }

    @Test("Plan §A11: reconcile preserves wpeOrigin when active wallpaper is metalShader")
    func reconcilePreservesOriginForShader() {
        var config = makeConfiguration(activeWallpaper: .metalShader(.waves))
        let origin = makeOrigin(workshopID: "222", cacheRelativePath: "wpe-cache/222")
        config.wpeOrigin = origin
        WPEOriginReconciler().reconcile(&config, event: .userReplacedActiveWallpaper(previous: nil))
        #expect(config.wpeOrigin == origin, "Shader switch is transient; switching back to Video/HTML must restore the badge.")
    }

    @Test("Reconcile clears origin when video bookmark no longer matches cache")
    func reconcileClearsWhenVideoBookmarkMismatches() {
        var config = makeConfiguration(activeWallpaper: .video(bookmarkData: Data("non-wpe".utf8)))
        config.wpeOrigin = makeOrigin(workshopID: "333", cacheRelativePath: "wpe-cache/333")
        WPEOriginReconciler().reconcile(&config, event: .userReplacedActiveWallpaper(previous: nil))
        #expect(config.wpeOrigin == nil)
    }

    @Test("Reconcile clears origin when html source is not a folder bookmark")
    func reconcileClearsWhenHTMLNotFolder() {
        var config = makeConfiguration(activeWallpaper: .html(source: .url(URL(string: "https://example.com")!), config: .default))
        config.wpeOrigin = makeOrigin(workshopID: "444", cacheRelativePath: "wpe-cache/444")
        WPEOriginReconciler().reconcile(&config, event: .userReplacedActiveWallpaper(previous: nil))
        #expect(config.wpeOrigin == nil)
    }

    @Test("Reconcile clears origin when html folder bookmark mismatches cache")
    func reconcileClearsWhenHTMLFolderMismatches() {
        var config = makeConfiguration(activeWallpaper: .html(
            source: .folder(bookmarkData: Data("non-wpe".utf8), indexFileName: "index.html"),
            config: .default
        ))
        config.wpeOrigin = makeOrigin(workshopID: "555", cacheRelativePath: "wpe-cache/555")
        WPEOriginReconciler().reconcile(&config, event: .userReplacedActiveWallpaper(previous: nil))
        #expect(config.wpeOrigin == nil)
    }

    // MARK: - WPEOrigin.matchesBookmark

    @Test("matchesBookmark returns false when cacheRelativePath is empty/nil")
    func matchesBookmarkRejectsMissingCachePath() {
        let origin = makeOrigin(workshopID: "666", cacheRelativePath: nil)
        #expect(!WPEOrigin.matchesBookmark(Data("anything".utf8), origin: origin))

        var emptyPathOrigin = origin
        emptyPathOrigin.cacheRelativePath = ""
        #expect(!WPEOrigin.matchesBookmark(Data("anything".utf8), origin: emptyPathOrigin))
    }

    @Test("matchesBookmark returns false when bookmarkData is invalid")
    func matchesBookmarkRejectsInvalidBookmark() {
        let origin = makeOrigin(workshopID: "777", cacheRelativePath: "wpe-cache/777")
        #expect(!WPEOrigin.matchesBookmark(Data([0xDE, 0xAD, 0xBE, 0xEF]), origin: origin))
    }

    @Test("sourcePreviewURL rejects preview paths that escape the source folder")
    func sourcePreviewURLRejectsTraversalPreviewName() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let bookmark = try folder.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let origin = WPEOrigin(
            workshopID: "preview-traversal",
            title: "Preview Traversal",
            originalType: .scene,
            sourceFolderBookmark: bookmark,
            cacheRelativePath: nil,
            previewFileName: "../secret.gif"
        )

        #expect(origin.sourcePreviewURL == nil)
    }

    @Test("sourcePreviewURL resolves valid previews under the source folder")
    func sourcePreviewURLAcceptsNestedPreviewName() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let images = folder.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let preview = images.appendingPathComponent("preview.gif")
        try Data([0x47, 0x49, 0x46]).write(to: preview)

        let bookmark = try folder.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let origin = WPEOrigin(
            workshopID: "preview-valid",
            title: "Preview Valid",
            originalType: .scene,
            sourceFolderBookmark: bookmark,
            cacheRelativePath: nil,
            previewFileName: "images/preview.gif"
        )

        let expectedPath = preview.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(origin.sourcePreviewURL?.path == expectedPath)
    }

    @Test("matchesBookmark rejects source-folder video entry paths that escape")
    func matchesBookmarkRejectsSourceFolderVideoTraversalEntryFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-source-video-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("source", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let externalVideo = root.appendingPathComponent("secret.mp4")
        try Data([0x00]).write(to: externalVideo)

        let folderBookmark = try folder.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let videoBookmark = try externalVideo.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let origin = WPEOrigin(
            workshopID: "source-video-traversal",
            title: "Source Video Traversal",
            originalType: .video,
            sourceFolderBookmark: folderBookmark,
            cacheRelativePath: nil,
            previewFileName: nil,
            entryFile: "../secret.mp4",
            resourceLocation: .sourceFolder
        )

        #expect(!WPEOrigin.matchesBookmark(videoBookmark, origin: origin))
    }

    @Test("matchesBookmark accepts source-folder video entry paths inside the source folder")
    func matchesBookmarkAcceptsSourceFolderVideoEntryFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-source-video-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent("clip.mp4")
        try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x00]).write(to: video)

        let folderBookmark = try folder.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let videoBookmark = try video.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let origin = WPEOrigin(
            workshopID: "source-video-valid",
            title: "Source Video Valid",
            originalType: .video,
            sourceFolderBookmark: folderBookmark,
            cacheRelativePath: nil,
            previewFileName: nil,
            entryFile: "media/clip.mp4",
            resourceLocation: .sourceFolder
        )

        #expect(WPEOrigin.matchesBookmark(videoBookmark, origin: origin))
    }

    @Test("matchesBookmark returns true for a real security-scoped bookmark inside the cache")
    func matchesBookmarkAcceptsRealBookmarkInsideCache() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-match-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let payload = temp.appendingPathComponent("payload.mp4")
        try Data([0x00]).write(to: payload)

        let bookmark = try payload.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let origin = makeOrigin(workshopID: "888", cacheRelativePath: "wpe-cache/888")
        #expect(!WPEOrigin.matchesBookmark(bookmark, origin: origin))
    }

    // MARK: - Plan §A14: removeWPEImport semantic (history side)

    @Test("Plan §A14: SettingsManager.removeWPEImport drops only the requested workshop")
    func removeWPEImportTargetsOnlyMatchingWorkshop() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            let now = Date()
            manager.recordWPEImport(WPEHistoryEntry(origin: makeOrigin(workshopID: "alpha"), importedAt: now, lastUsedAt: now))
            manager.recordWPEImport(WPEHistoryEntry(origin: makeOrigin(workshopID: "beta"), importedAt: now, lastUsedAt: now))
            manager.recordWPEImport(WPEHistoryEntry(origin: makeOrigin(workshopID: "gamma"), importedAt: now, lastUsedAt: now))

            manager.removeWPEImport(workshopID: "beta")

            let remaining = manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
            #expect(remaining == ["gamma", "alpha"])
        }
    }

    // MARK: - Helpers

    private func makeConfiguration(activeWallpaper: WallpaperContent) -> ScreenConfiguration {
        ScreenConfiguration(screenID: 0, wallpaper: activeWallpaper)
    }

    private func makeOrigin(
        workshopID: String,
        cacheRelativePath: String? = "wpe-cache/\(UUID().uuidString)"
    ) -> WPEOrigin {
        WPEOrigin(
            workshopID: workshopID,
            title: "Title \(workshopID)",
            originalType: .video,
            sourceFolderBookmark: Data(workshopID.utf8),
            cacheRelativePath: cacheRelativePath,
            previewFileName: "preview.gif"
        )
    }

    private func withIsolatedGlobalSettings(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [
            "screenConfigurations",
            "globalSettings",
            "AerialsLibrary.DirectoryBookmark",
            "WallpaperBookmarks.v1",
            "TrustedHTMLHosts.v1",
        ]
        let previousValues = keys.reduce(into: [String: Any]()) { result, key in
            result[key] = defaults.object(forKey: key)
        }

        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        defer {
            SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        try body()
    }
}
