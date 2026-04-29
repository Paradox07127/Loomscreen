import Foundation

/// Typed model of a Wallpaper Engine `project.json` manifest.
struct WallpaperEngineProject: Sendable, Equatable {
    let workshopID: String
    let title: String
    let entryFile: String
    let type: WPEType
    let previewFileName: String?
    let propertyCount: Int

    static func read(from folder: URL) throws -> Self {
        let manifestURL = folder.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw WPEProjectError.manifestNotFound
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw WPEProjectError.manifestUnreadable
        }

        let decoded: DecodedManifest
        do {
            decoded = try JSONDecoder().decode(DecodedManifest.self, from: data)
        } catch {
            throw WPEProjectError.manifestMalformed(error.localizedDescription)
        }

        let workshopID = Self.trimmed(decoded.workshopid) ?? folder.lastPathComponent
        guard Self.isSafePathComponent(workshopID) else {
            throw WPEProjectError.manifestMalformed("Invalid workshop id")
        }
        guard let entryFile = Self.trimmed(decoded.file), Self.isSafeRelativePath(entryFile) else {
            throw WPEProjectError.manifestMalformed("Invalid project entry file")
        }

        return Self(
            workshopID: workshopID,
            title: Self.trimmed(decoded.title) ?? workshopID,
            entryFile: entryFile,
            type: WPEType(rawWPEValue: decoded.type),
            previewFileName: Self.resolvePreviewFileName(decoded.preview, in: folder),
            propertyCount: decoded.general?.properties?.count ?? 0
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolvePreviewFileName(_ manifestValue: String?, in folder: URL) -> String? {
        if let preview = trimmed(manifestValue), isSafeRelativePath(preview) {
            return preview
        }

        for candidate in ["preview.gif", "preview.jpg", "preview.png"] {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        return nil
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("..")
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("..")
            && value != "."
    }
}

enum WPEProjectError: Error, Equatable, Sendable {
    case manifestNotFound
    case manifestUnreadable
    case manifestMalformed(String)
}

private struct DecodedManifest: Decodable, Sendable {
    let workshopid: String?
    let title: String?
    let file: String?
    let type: String?
    let preview: String?
    let general: DecodedGeneral?

    private enum CodingKeys: String, CodingKey {
        case workshopid
        case title
        case file
        case type
        case preview
        case general
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workshopid = try container.decodeFlexibleString(forKey: .workshopid)
        title = try container.decodeFlexibleString(forKey: .title)
        file = try container.decodeFlexibleString(forKey: .file)
        type = try container.decodeFlexibleString(forKey: .type)
        preview = try container.decodeFlexibleString(forKey: .preview)
        general = try? container.decode(DecodedGeneral.self, forKey: .general)
    }
}

private struct DecodedGeneral: Decodable, Sendable {
    let properties: [String: IgnoredJSON]?
}

private struct IgnoredJSON: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) throws -> String? {
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Int64.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}
