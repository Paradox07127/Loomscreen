import Foundation

/// Resolves the on-disk location for app configuration files. Centralized so
/// the same path is used by every typed store (and by tests, which inject a
/// temporary root via `init(root:)`).
///
/// Layout (matches Apple's HIG for non-document app data):
///
///   ~/Library/Application Support/<bundle-id>/Configuration/
///       screen-configurations.json
///       global-settings.json
///       wallpaper-bookmarks.json
///
/// The directory is created lazily on first write — read paths never create
/// directories, so an unmigrated install reads `nil` and the migration code
/// in `SettingsManager` handles the seed-from-`UserDefaults` step.
///
/// ## App Sandbox readiness
///
/// We currently ship via Developer ID + Notarization (not sandboxed). If we
/// ever turn on `com.apple.security.app-sandbox` the resolver below still
/// returns the *correct* path because macOS automatically rewrites
/// `applicationSupportDirectory` to
/// `~/Library/Containers/<bundle-id>/Data/Library/Application Support/`.
///
/// **Migration concern**: an existing user upgrading to a sandboxed build
/// would no longer see their old non-container files. The first sandboxed
/// release MUST ship with one of:
/// 1. A `<bundle-id>.sb` container-migration manifest that maps the legacy
///    `~/Library/Application Support/<bundle-id>/Configuration/` into the
///    sandbox container, OR
/// 2. An in-app "import legacy data" path that reads via Apple's temporary
///    user-selected file extension and copies forward.
///
/// **Entitlement concern**: the current entitlements only grant
/// `user-selected.read-only`. A sandboxed build that needs Export to write
/// to user-picked locations must also grant `user-selected.read-write`. The
/// SwiftUI `.fileExporter` modifier handles the security-scoped extension
/// internally — but the entitlement is still required.
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

    /// Test/migration injection point. The directory is used verbatim.
    init(root: URL) {
        self.root = root
    }

    func url(for file: File) -> URL {
        root.appendingPathComponent(file.rawValue, isDirectory: false)
    }
}
