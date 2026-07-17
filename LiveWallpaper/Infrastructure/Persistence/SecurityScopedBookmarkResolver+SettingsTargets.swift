import Foundation
import LiveWallpaperCore

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

}
