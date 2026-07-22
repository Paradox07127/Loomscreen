import Foundation
import LiveWallpaperCore

// App-target bookmark refresh handlers backed by SettingsManager.

extension SecurityScopedBookmarkResolver.Target {
    /// User-granted Workshop library root scanned for scene projects.
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
