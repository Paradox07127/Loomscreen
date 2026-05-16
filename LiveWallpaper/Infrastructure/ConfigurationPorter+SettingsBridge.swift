import Foundation

/// SettingsManager-backed entry points for the Core `ConfigurationPorter`.
/// Stays in the main target — Core stays free of the SettingsManager and
/// `BookmarkStore.shared` singleton (both still tied to the legacy
/// UserDefaults-backed persistence). Lite will eventually bind its own
/// SKU-scoped pair behind the same call site through dependency injection.
@MainActor
extension ConfigurationPorter {
    /// Snapshots the current state into a `ConfigurationBundle`. Reads run
    /// through `SettingsManager` so caches stay consistent.
    static func currentBundle() -> ConfigurationBundle {
        let manager = SettingsManager.shared
        return ConfigurationBundle(
            screenConfigurations: manager.loadConfigurations(),
            globalSettings: manager.loadGlobalSettings(),
            wallpaperBookmarks: manager.loadWallpaperBookmarks()
        )
    }

    /// Writes the current state to `destination` atomically. Returns the
    /// URL on success. The caller is responsible for security-scoped
    /// resource access if `destination` was returned by `NSSavePanel`.
    @discardableResult
    static func export(to destination: URL) throws -> URL {
        try ConfigurationPorter.export(currentBundle(), to: destination)
    }

    /// Applies a decoded bundle through SettingsManager + BookmarkStore.shared.
    /// Each section is independently optional so partial exports work.
    @discardableResult
    static func apply(_ bundle: ConfigurationBundle) -> ApplySummary {
        let manager = SettingsManager.shared
        var summary = ApplySummary(displayCount: nil, bookmarkCount: nil, didRestoreGlobalSettings: false)

        if let configurations = bundle.screenConfigurations {
            manager.replaceAllConfigurations(configurations)
            summary.displayCount = configurations.count
        }

        if let global = bundle.globalSettings {
            manager.saveGlobalSettings(global)
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
