#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Single source of truth for "which WPE scenes can the user still reach". Used
/// by launch cache GC and the cache-settings purge/reclaim UI so neither path
/// reclaims a scene that's applied, bookmarked, or in recent history.
@MainActor
enum WPESceneReachability {
    /// Workshop ids referenced by any applied screen config, saved bookmark, or
    /// recent import — plus all of their declared dependencies.
    static func referencedWorkshopIDs() -> Set<String> {
        var ids: Set<String> = []

        func add(_ origin: WPEOrigin?) {
            guard let origin else { return }
            ids.insert(origin.workshopID)
            ids.formUnion(origin.dependencyWorkshopIDs)
        }
        func add(_ descriptor: SceneDescriptor?) {
            guard let descriptor else { return }
            ids.insert(descriptor.workshopID)
            ids.formUnion(descriptor.dependencyWorkshopIDs)
        }

        for config in SettingsManager.shared.loadConfigurations() {
            add(config.activeWallpaper.sceneDescriptor)
            add(config.wpeOrigin)
        }
        for entry in SettingsManager.shared.loadGlobalSettings().recentWPEImports {
            add(entry.origin)
        }
        for bookmark in BookmarkStore.shared.bookmarks {
            add(bookmark.wpeOrigin)
            add(bookmark.content.sceneDescriptor)
        }
        return ids.filter { !$0.isEmpty }
    }

    /// Ids whose live **content** reads in place from a source `scene.pkg` —
    /// that archive is a runtime dependency and must never be reclaimed. Covers
    /// every packaged type (scene, video, web), not just `.scene`: a packaged
    /// video's content *is* a bookmark to the `.pkg`.
    ///
    /// Recent-history-only ids are deliberately absent. The reclaimer only ever
    /// considers ids that still have a completed extraction cache, and a history
    /// entry is re-resolved through `WPECachedContentResolver` on apply — which
    /// falls back to that cache when the source `.pkg` is gone. An applied or
    /// bookmarked item cannot: its stored content already points at the `.pkg`,
    /// and nothing re-derives it.
    static func packageBackedWorkshopIDs() -> Set<String> {
        packageBackedWorkshopIDs(
            configurations: SettingsManager.shared.loadConfigurations(),
            bookmarks: BookmarkStore.shared.bookmarks
        )
    }

    static func packageBackedWorkshopIDs(
        configurations: [ScreenConfiguration],
        bookmarks: [WallpaperBookmark]
    ) -> Set<String> {
        var ids: Set<String> = []
        func add(_ content: WallpaperContent, _ origin: WPEOrigin?) {
            guard content.mayReadFromSourcePackage else { return }
            // Only a scene descriptor carries its own id; a packaged video/web
            // knows it solely through the paired origin.
            guard let id = content.sceneDescriptor?.workshopID ?? origin?.workshopID,
                  !id.isEmpty else { return }
            ids.insert(id)
        }
        for config in configurations {
            add(config.activeWallpaper, config.wpeOrigin)
        }
        for bookmark in bookmarks {
            add(bookmark.content, bookmark.wpeOrigin)
        }
        return ids
    }
}
#endif
