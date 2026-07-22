import Foundation

/// Resolves the sandbox-aware configuration directory shared by typed stores and migrations.
struct ConfigurationDirectory {
    enum File: String {
        case screenConfigurations = "screen-configurations.json"
        case globalSettings = "global-settings.json"
        case wallpaperBookmarks = "wallpaper-bookmarks.json"
    }

    let root: URL

    /// Standard container-aware production location.
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
