import Foundation

// Pro-side typed `Target`s that persist refreshed bookmarks through
// `SettingsManager.shared`. The Resolver core lives in LiveWallpaperCore;
// these extensions stay in the main target because they reach into
// SettingsManager which isn't part of Core (yet).

extension SecurityScopedBookmarkResolver.Target {
    /// Workshop library root — the user-granted `~/Documents/Live Wallpapers/<appid>/`
    /// folder scanned for WPE projects.
    static var workshopLibraryRoot: Self {
        Self(label: "workshopLibraryRoot") { original, refreshed in
            Task { @MainActor in
                guard SettingsManager.shared.loadWorkshopLibraryRootBookmark() == original else {
                    Logger.info(
                        "[bookmark/workshopLibraryRoot] skipped stale refresh save — stored bookmark changed between resolve and save",
                        category: .fileAccess
                    )
                    return
                }
                SettingsManager.shared.saveWorkshopLibraryRootBookmark(refreshed)
            }
        }
    }

    /// Wallpaper Engine install root — the directory containing `assets/`
    /// the user authorised so the renderer can fall back to engine builtins.
    static var wpeEngineAssets: Self {
        Self(label: "wpeEngineAssets") { original, refreshed in
            Task { @MainActor in
                guard SettingsManager.shared.loadWPEEngineAssetsBookmark() == original else {
                    Logger.info(
                        "[bookmark/wpeEngineAssets] skipped stale refresh save — stored bookmark changed between resolve and save",
                        category: .fileAccess
                    )
                    return
                }
                SettingsManager.shared.saveWPEEngineAssetsBookmark(refreshed)
            }
        }
    }

    /// Apple Aerials wallpaper library directory.
    static var aerialsDirectory: Self {
        Self(label: "aerialsDirectory") { original, refreshed in
            Task { @MainActor in
                guard SettingsManager.shared.loadAerialsDirectoryBookmark() == original else {
                    Logger.info(
                        "[bookmark/aerialsDirectory] skipped stale refresh save — stored bookmark changed between resolve and save",
                        category: .fileAccess
                    )
                    return
                }
                SettingsManager.shared.saveAerialsDirectoryBookmark(refreshed)
            }
        }
    }
}
