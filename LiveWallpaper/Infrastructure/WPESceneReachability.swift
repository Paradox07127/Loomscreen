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

    /// Subset whose live descriptor reads in place from a packed `scene.pkg`.
    /// Their source archive is a runtime dependency and must never be reclaimed.
    static func packageBackedWorkshopIDs() -> Set<String> {
        var ids: Set<String> = []
        func add(_ descriptor: SceneDescriptor?) {
            guard let descriptor, case .packageSource = descriptor.assetStorage else { return }
            ids.insert(descriptor.workshopID)
        }
        for config in SettingsManager.shared.loadConfigurations() {
            add(config.activeWallpaper.sceneDescriptor)
        }
        for bookmark in BookmarkStore.shared.bookmarks {
            add(bookmark.content.sceneDescriptor)
        }
        return ids
    }
}
#endif
