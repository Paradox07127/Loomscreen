import Foundation
import LiveWallpaperCore

/// Connects the core configuration porter to app settings and bookmarks.
@MainActor
extension ConfigurationPorter {
    static func currentBundle() -> ConfigurationBundle {
        let manager = SettingsManager.shared
        return ConfigurationBundle(
            screenConfigurations: manager.loadConfigurations(),
            globalSettings: manager.loadGlobalSettings(),
            wallpaperBookmarks: manager.loadWallpaperBookmarks()
        )
    }

    @discardableResult
    static func export(to destination: URL) throws -> URL {
        try ConfigurationPorter.export(currentBundle(), to: destination)
    }

    @discardableResult
    static func apply(_ bundle: ConfigurationBundle) -> ApplySummary {
        let manager = SettingsManager.shared
        var summary = ApplySummary(displayCount: nil, bookmarkCount: nil, didRestoreGlobalSettings: false)

        if let configurations = bundle.screenConfigurations {
            manager.replaceAllConfigurations(configurations)
            summary.displayCount = configurations.count
        }

        if let global = bundle.globalSettings {
            // Developer Mode is a local security opt-in and must not transfer through backups.
            var sanitizedGlobal = global
            sanitizedGlobal.developerModeEnabled = false
            manager.saveGlobalSettings(sanitizedGlobal)
            summary.didRestoreGlobalSettings = true
        }

        if let bookmarks = bundle.wallpaperBookmarks {
            manager.saveWallpaperBookmarks(bookmarks)
            BookmarkStore.shared.reload()
            summary.bookmarkCount = bookmarks.count
        }

        Logger.info(
            "Configuration import applied (displays=\(summary.displayCount ?? 0), global=\(summary.didRestoreGlobalSettings), bookmarks=\(summary.bookmarkCount ?? 0))",
            category: .settings
        )

        return summary
    }
}
