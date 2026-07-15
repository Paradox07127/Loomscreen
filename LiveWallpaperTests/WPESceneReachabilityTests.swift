#if !LITE_BUILD
import Foundation
import Testing
import LiveWallpaperCore
@testable import LiveWallpaper

/// Locks the "never reclaim a live `scene.pkg`" rule that gates the download
/// archive reclaimer. Every packaged type reads its assets in place from the
/// source archive, so trashing it breaks the applied wallpaper — the reclaimer
/// subtracts this set from its candidates.
@Suite("WPE scene reachability: package-backed ids")
@MainActor
struct WPESceneReachabilityTests {
    private func origin(
        _ workshopID: String,
        type: WPEType,
        entryFile: String
    ) -> WPEOrigin {
        WPEOrigin(
            workshopID: workshopID,
            title: "item-\(workshopID)",
            originalType: type,
            sourceFolderBookmark: Data("bookmark".utf8),
            cacheRelativePath: "wpe-cache/\(workshopID)",
            previewFileName: nil,
            entryFile: entryFile,
            // Legacy imports persist `.cache`; those are exactly the ids that
            // still have an extraction cache and so reach the reclaimer.
            resourceLocation: .cache
        )
    }

    private func config(
        _ content: WallpaperContent,
        origin: WPEOrigin?,
        screenID: UInt32 = 1
    ) -> ScreenConfiguration {
        var config = ScreenConfiguration(screenID: screenID, wallpaper: content)
        config.wpeOrigin = origin
        return config
    }

    private func sceneDescriptor(_ workshopID: String, storage: SceneAssetStorage) -> SceneDescriptor {
        SceneDescriptor(
            workshopID: workshopID,
            cacheRelativePath: "wpe-cache/\(workshopID)",
            entryFile: "scene.json",
            capabilityTier: .imageOnly,
            assetStorage: storage
        )
    }

    /// The user-data bug: a packaged video's content is a bookmark to
    /// `scene.pkg` itself, but the id was only recoverable from the paired
    /// origin — so a `sceneDescriptor`-only reachability scan missed it and the
    /// reclaimer trashed the archive the wallpaper was playing from.
    @Test("An applied packaged video protects its source scene.pkg")
    func packagedVideoIsPackageBacked() {
        let ids = WPESceneReachability.packageBackedWorkshopIDs(
            configurations: [
                config(
                    .video(bookmarkData: Data("pkg".utf8), packageEntryName: "video.mp4"),
                    origin: origin("111", type: .video, entryFile: "video.mp4")
                )
            ],
            bookmarks: []
        )
        #expect(ids == ["111"])
    }

    /// The counterweight: a loose video really does read from the extracted
    /// cache, so its archive stays reclaimable. Without this, "protect
    /// everything with an origin" would pass the test above and silently kill
    /// the feature.
    @Test("An applied loose video leaves its archive reclaimable")
    func looseVideoIsNotPackageBacked() {
        let ids = WPESceneReachability.packageBackedWorkshopIDs(
            configurations: [
                config(
                    .video(bookmarkData: Data("loose".utf8)),
                    origin: origin("222", type: .video, entryFile: "video.mp4")
                )
            ],
            bookmarks: []
        )
        #expect(ids.isEmpty)
    }

    @Test("An applied packaged web wallpaper protects its source scene.pkg")
    func packagedWebIsPackageBacked() {
        let ids = WPESceneReachability.packageBackedWorkshopIDs(
            configurations: [
                config(
                    .html(
                        source: .folder(bookmarkData: Data("folder".utf8), indexFileName: "index.html"),
                        config: HTMLConfig()
                    ),
                    origin: origin("333", type: .web, entryFile: "index.html")
                )
            ],
            bookmarks: []
        )
        #expect(ids == ["333"])
    }

    @Test("A package-source scene stays protected")
    func packageSourceSceneIsPackageBacked() {
        let ids = WPESceneReachability.packageBackedWorkshopIDs(
            configurations: [
                config(
                    .scene(sceneDescriptor("444", storage: .packageSource(fileName: "scene.pkg"))),
                    origin: origin("444", type: .scene, entryFile: "scene.json")
                )
            ],
            bookmarks: []
        )
        #expect(ids == ["444"])
    }

    @Test("A legacy cache-backed scene leaves its archive reclaimable")
    func cacheBackedSceneIsNotPackageBacked() {
        let ids = WPESceneReachability.packageBackedWorkshopIDs(
            configurations: [
                config(
                    .scene(sceneDescriptor("555", storage: .cache)),
                    origin: origin("555", type: .scene, entryFile: "scene.json")
                )
            ],
            bookmarks: []
        )
        #expect(ids.isEmpty)
    }

    @Test("Bookmarks are scanned alongside applied configurations")
    func bookmarkedPackagedVideoIsPackageBacked() {
        let ids = WPESceneReachability.packageBackedWorkshopIDs(
            configurations: [],
            bookmarks: [
                WallpaperBookmark(
                    label: "saved",
                    content: .video(bookmarkData: Data("pkg".utf8), packageEntryName: "video.mp4"),
                    wpeOrigin: origin("666", type: .video, entryFile: "video.mp4")
                )
            ]
        )
        #expect(ids == ["666"])
    }

    /// A packaged video with no origin has no id to protect; it must not widen
    /// the set with an empty string (which would match nothing and mask the gap).
    @Test("A packaged video without an origin contributes no id")
    func packagedVideoWithoutOriginContributesNothing() {
        let ids = WPESceneReachability.packageBackedWorkshopIDs(
            configurations: [
                config(
                    .video(bookmarkData: Data("pkg".utf8), packageEntryName: "video.mp4"),
                    origin: nil
                )
            ],
            bookmarks: []
        )
        #expect(ids.isEmpty)
    }

    /// Non-WPE content never contributes, even on a screen whose origin lingers.
    @Test("Shader and monitor wallpapers contribute no ids")
    func nonPackageContentContributesNothing() {
        let ids = WPESceneReachability.packageBackedWorkshopIDs(
            configurations: [
                config(.metalShader(.builtin(.waves)), origin: origin("777", type: .scene, entryFile: "scene.json"), screenID: 1),
                config(.monitor(.default), origin: origin("888", type: .scene, entryFile: "scene.json"), screenID: 2)
            ],
            bookmarks: []
        )
        #expect(ids.isEmpty)
    }
}
#endif
