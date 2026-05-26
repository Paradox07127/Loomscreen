import Foundation

/// Resolves the on-disk location for app configuration files. Centralized so
/// every typed store (and tests via `init(root:)`) shares the same path.
///
/// Layout: `~/Library/Application Support/<bundle-id>/Configuration/{screen-configurations,global-settings,wallpaper-bookmarks}.json`
/// Created lazily on first write — read paths return `nil` for unmigrated installs
/// and `SettingsManager` handles the seed-from-`UserDefaults` step.
///
/// If sandboxing is ever enabled, `applicationSupportDirectory` is auto-rewritten
/// by macOS to the container path; a future sandboxed release would still need a
/// legacy-data migration step + `user-selected.read-write` entitlement for Export.
struct ConfigurationDirectory {
    enum File: String {
        case screenConfigurations = "screen-configurations.json"
        case globalSettings = "global-settings.json"
        case wallpaperBookmarks = "wallpaper-bookmarks.json"
    }

    let root: URL

    /// Standard production location.
    init(fileManager: FileManager = .default) {
        let bundleID = Bundle.main.bundleIdentifier ?? "Taijia.LiveWallpaper"
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        self.root = appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Configuration", isDirectory: true)
    }

    /// Test/migration injection point.
    init(root: URL) {
        self.root = root
    }

    func url(for file: File) -> URL {
        root.appendingPathComponent(file.rawValue, isDirectory: false)
    }
}
