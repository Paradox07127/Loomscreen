import Foundation

/// Exports the user's current configuration to a `.lwconfig` JSON file and
/// imports it back. Stateless — all reads/writes go through `SettingsManager`
/// so the rest of the app sees a single source of truth.
///
/// Limitations the UI must communicate:
/// - Security-scoped bookmarks (video files, HTML folders, the Workshop
///   library root) are tied to this device's data-protection keychain.
///   Importing on another Mac will keep the metadata but the user has to
///   reselect the actual files. This is a macOS-level constraint, not a
///   bug in the porter.
@MainActor
enum ConfigurationPorter {
    enum ImportError: Error, LocalizedError {
        case invalidFile(reason: String)
        case fileTooLarge(bytes: Int)
        case unsupportedSchemaVersion(found: Int, supported: Int)
        case bundleMismatch(expected: String, found: String)

        var errorDescription: String? {
            switch self {
            case .invalidFile(let reason):
                return String(
                    localized: "Couldn't read this configuration file: \(reason)",
                    comment: "Import failure: the file isn't a valid LiveWallpaper config bundle."
                )
            case .fileTooLarge(let bytes):
                return String(
                    localized: "This file is too large to import (\(bytes) bytes). Configuration backups are usually well under 10 MB.",
                    comment: "Import failure: the file exceeds the size cap and is likely not a real config bundle."
                )
            case .unsupportedSchemaVersion(let found, let supported):
                return String(
                    localized: "This configuration was made with a different version (schema \(found)). This build supports schema 1 through \(supported).",
                    comment: "Import failure: schema is outside the supported range."
                )
            case .bundleMismatch(let expected, let found):
                return String(
                    localized: "This configuration is for a different app (\(found)). Expected \(expected).",
                    comment: "Import failure: bundle identifier doesn't match."
                )
            }
        }
    }

    /// Hard import cap. Real configs top out around a few hundred KB even
    /// with large playlists; anything bigger is either malicious or not
    /// actually a config bundle. Keeps `decode` from blocking MainActor for
    /// seconds on a hostile file.
    static let maxImportFileSize: Int = 16 * 1024 * 1024

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

    /// Encodes the bundle to pretty-printed JSON so users who open the file
    /// in a text editor see readable content. `sortedKeys` keeps diffs
    /// stable between exports.
    static func encode(_ bundle: ConfigurationBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    /// Writes the bundle to `destination` atomically. Returns the URL on
    /// success. The caller is responsible for security-scoped resource
    /// access if `destination` was returned by `NSSavePanel`.
    @discardableResult
    static func export(to destination: URL) throws -> URL {
        let data = try encode(currentBundle())
        try data.write(to: destination, options: [.atomic])
        Logger.info(
            "Configuration exported to \(destination.lastPathComponent) (\(data.count) bytes)",
            category: .settings
        )
        return destination
    }

    /// Decodes (but does NOT apply) a bundle for preview / dialog purposes.
    /// Enforces a size cap so a hostile or accidental enormous file can't
    /// freeze MainActor while we read it.
    static func decode(from source: URL) throws -> ConfigurationBundle {
        // Cheap size check before reading the bytes.
        if let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxImportFileSize {
            throw ImportError.fileTooLarge(bytes: size)
        }

        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw ImportError.invalidFile(reason: error.localizedDescription)
        }

        // Defense-in-depth: some filesystems lie about size; double-check
        // the actual byte count.
        guard data.count <= maxImportFileSize else {
            throw ImportError.fileTooLarge(bytes: data.count)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle: ConfigurationBundle
        do {
            bundle = try decoder.decode(ConfigurationBundle.self, from: data)
        } catch {
            throw ImportError.invalidFile(reason: error.localizedDescription)
        }

        // Schema version must be a positive integer within our supported
        // range. Reject 0 / negative / future-version files explicitly so
        // we don't silently apply data we don't understand.
        guard bundle.schemaVersion >= 1,
              bundle.schemaVersion <= ConfigurationBundle.currentSchemaVersion else {
            throw ImportError.unsupportedSchemaVersion(
                found: bundle.schemaVersion,
                supported: ConfigurationBundle.currentSchemaVersion
            )
        }

        let expectedBundleID = Bundle.main.bundleIdentifier ?? "Taijia.LiveWallpaper"
        guard bundle.appBundleID == expectedBundleID else {
            throw ImportError.bundleMismatch(
                expected: expectedBundleID,
                found: bundle.appBundleID
            )
        }

        return bundle
    }

    /// Result of an `apply` call. The view layer renders each restored
    /// section through its own localized format string so we never have to
    /// build a sentence with manual `joined(separator:)` (which would break
    /// RTL languages and prevent translators from reordering phrases).
    struct ApplySummary: Sendable {
        var displayCount: Int?
        var bookmarkCount: Int?
        var didRestoreGlobalSettings: Bool

        var isEmpty: Bool {
            displayCount == nil && bookmarkCount == nil && !didRestoreGlobalSettings
        }
    }

    /// Applies a decoded bundle. Each section is independently optional so
    /// partial exports work. Returns a structured summary so the UI can
    /// render a fully localized success message without string surgery.
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

    static func suggestedExportFileName(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay]
        let stamp = formatter.string(from: now).replacingOccurrences(of: "-", with: "")
        return "LiveWallpaper-\(stamp).\(ConfigurationBundle.fileExtension)"
    }
}
