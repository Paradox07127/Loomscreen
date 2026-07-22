import Foundation

/// Stateless codec for `.lwconfig` bundles, independent of app-level settings stores.
/// Security-scoped bookmarks are device-bound, so imported bundles may require users to reselect files.
@MainActor
public enum ConfigurationPorter {
    public enum ImportError: Error, LocalizedError {
        case invalidFile(reason: String)
        case fileTooLarge(bytes: Int)
        case unsupportedSchemaVersion(found: Int, supported: Int)
        case bundleMismatch(expected: String, found: String)

        public var errorDescription: String? {
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

    /// Rejects oversized input before decoding to bound work on untrusted files.
    public static let maxImportFileSize: Int = 16 * 1024 * 1024

    /// Pretty-printed so the file is readable if a user opens it in a text editor.
    public static func encode(_ bundle: ConfigurationBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    @discardableResult
    public static func export(_ bundle: ConfigurationBundle, to destination: URL) throws -> URL {
        let data = try encode(bundle)
        try data.write(to: destination, options: [.atomic])
        Logger.info(
            "Configuration exported to \(destination.lastPathComponent) (\(data.count) bytes)",
            category: .settings
        )
        return destination
    }

    /// Decodes but does NOT apply — for preview / dialog purposes.
    public static func decode(from source: URL) throws -> ConfigurationBundle {
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

    /// Structured import summary rendered through localized section-specific strings.
    public struct ApplySummary: Sendable {
        public var displayCount: Int?
        public var bookmarkCount: Int?
        public var didRestoreGlobalSettings: Bool

        public init(displayCount: Int? = nil, bookmarkCount: Int? = nil, didRestoreGlobalSettings: Bool = false) {
            self.displayCount = displayCount
            self.bookmarkCount = bookmarkCount
            self.didRestoreGlobalSettings = didRestoreGlobalSettings
        }

        public var isEmpty: Bool {
            displayCount == nil && bookmarkCount == nil && !didRestoreGlobalSettings
        }
    }

    public static func suggestedExportFileName(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay]
        let stamp = formatter.string(from: now).replacingOccurrences(of: "-", with: "")
        return "LiveWallpaper-\(stamp).\(ConfigurationBundle.fileExtension)"
    }
}
