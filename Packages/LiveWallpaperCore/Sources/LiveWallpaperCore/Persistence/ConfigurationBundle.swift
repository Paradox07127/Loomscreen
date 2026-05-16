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

    /// Custom UTType registered via `UTExportedTypeDeclarations` in
    /// `LiveWallpaperInfo.plist`. Conforms to `public.json` so file panels
    /// also accept hand-edited `.json` exports, and gives Finder a stable
    /// icon + "Open With…" association for `.lwconfig` files.
    ///
    /// Falls back to `.json` only if the Info.plist registration somehow
    /// failed to load — exists purely so unit tests can run without the
    /// full app bundle context.
    public static let contentType: UTType = {
        if let registered = UTType("com.taijia.livewallpaper.config") {
            return registered
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
