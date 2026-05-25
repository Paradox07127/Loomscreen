import Foundation
import UniformTypeIdentifiers

/// Serializable payload exchanged by Export / Import. Versioned so future
/// schema changes can be migrated forward without rejecting older backups.
///
/// Schema:
/// - `schemaVersion`: bumped on breaking changes; current readers accept
///   anything ≤ `ConfigurationBundle.currentSchemaVersion`.
/// - `appBundleID`: lets us refuse to import another app's export.
/// - `appVersion` + `exportedAt`: informational, surfaced in the import
///   confirmation dialog.
/// - The three payload blobs are optional so a user can hand-edit the file
///   to ship only a subset (e.g., bookmarks-only backups).
public struct ConfigurationBundle: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let fileExtension = "lwconfig"

    /// Custom UTType registered via `UTExportedTypeDeclarations` in the host
    /// app's Info.plist. Each SKU registers its own identifier — Pro uses
    /// `com.taijia.livewallpaper.config` (`.lwconfig`), Loomscreen Lite uses
    /// `com.loomscreen.config` (`.loomscreen`). We probe bundle-derived first
    /// so any future SKU rename works without touching this code, then fall
    /// back to the historical identifier that matches the current bundle's
    /// SKU prefix, then `.json` for unit tests running outside a hosted
    /// bundle context. The order matters when both SKUs are installed side
    /// by side: a Pro test runner whose own `.config` UTI does not resolve
    /// must never accidentally fall through to Lite's UTI, or vice versa.
    public static let contentType: UTType = {
        var candidates: [String] = []
        if let bundleID = Bundle.main.bundleIdentifier {
            candidates.append(bundleID + ".config")
            if bundleID.lowercased().contains("loomscreen") {
                candidates.append("com.loomscreen.config")
                candidates.append("com.taijia.livewallpaper.config")
            } else {
                candidates.append("com.taijia.livewallpaper.config")
                candidates.append("com.loomscreen.config")
            }
        } else {
            candidates.append("com.taijia.livewallpaper.config")
            candidates.append("com.loomscreen.config")
        }
        for identifier in candidates {
            if let registered = UTType(identifier) {
                return registered
            }
        }
        return .json
    }()

    public var schemaVersion: Int
    public var appBundleID: String
    public var appVersion: String?
    public var exportedAt: Date
    public var screenConfigurations: [ScreenConfiguration]?
    public var globalSettings: GlobalSettings?
    public var wallpaperBookmarks: [WallpaperBookmark]?

    public init(
        schemaVersion: Int = ConfigurationBundle.currentSchemaVersion,
        appBundleID: String = Bundle.main.bundleIdentifier ?? "Taijia.LiveWallpaper",
        appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        exportedAt: Date = Date(),
        screenConfigurations: [ScreenConfiguration]? = nil,
        globalSettings: GlobalSettings? = nil,
        wallpaperBookmarks: [WallpaperBookmark]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.appBundleID = appBundleID
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.screenConfigurations = screenConfigurations
        self.globalSettings = globalSettings
        self.wallpaperBookmarks = wallpaperBookmarks
    }
}
