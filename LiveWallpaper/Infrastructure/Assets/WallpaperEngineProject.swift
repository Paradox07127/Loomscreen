#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

struct WallpaperEngineProject: Sendable, Equatable {
    let workshopID: String
    let title: String
    let entryFile: String
    let type: WPEType
    let previewFileName: String?
    let propertyCount: Int
    /// Workshop IDs declared as dependencies in `project.json`. WPE writes
    /// these as a top-level `dependencies` array and/or per-property values
    /// flagged as workshop references; we union both so the import service
    /// can warn the user before mounting an unrenderable scene.
    let dependencyWorkshopIDs: [String]
    /// `bin/` directory contains a Windows `.dll` plugin. macOS cannot run
    /// these; surfaced so the UI can show a permanent "won't run" badge.
    let requiresWindowsPlugin: Bool

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
        guard WPEPathSafety.isSafeWorkshopID(workshopID) else {
            throw WPEProjectError.manifestMalformed("Invalid workshop id")
        }
        guard let entryFile = Self.trimmed(decoded.file), WPEPathSafety.isSafeRelativePath(entryFile) else {
            throw WPEProjectError.manifestMalformed("Invalid project entry file")
        }

        return Self(
            workshopID: workshopID,
            title: Self.trimmed(decoded.title) ?? workshopID,
            entryFile: entryFile,
            type: WPEType(rawWPEValue: decoded.type),
            previewFileName: Self.resolvePreviewFileName(decoded.preview, in: folder),
            propertyCount: decoded.general?.properties?.count ?? 0,
            dependencyWorkshopIDs: Self.collectDependencyWorkshopIDs(from: decoded),
            requiresWindowsPlugin: Self.detectsWindowsPlugin(in: folder)
        )
    }

    /// Top-level `dependencies` array is the only manifest shape WPE actually emits in practice.
    private static func collectDependencyWorkshopIDs(from manifest: DecodedManifest) -> [String] {
        var ids = Set<String>()
        for raw in manifest.dependencies ?? [] {
            if let id = Self.trimmed(raw), Self.looksLikeWorkshopID(id) {
                ids.insert(id)
            }
        }
        return ids.sorted()
    }

    private static func looksLikeWorkshopID(_ value: String) -> Bool {
        let digits = value.count
        guard (9...20).contains(digits) else { return false }
        return value.allSatisfy(\.isNumber)
    }

    private static func detectsWindowsPlugin(in folder: URL) -> Bool {
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bin.path, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        guard let enumerator = FileManager.default.enumerator(
            at: bin,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "dll" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return true
            }
        }
        return false
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolvePreviewFileName(_ manifestValue: String?, in folder: URL) -> String? {
        if let preview = trimmed(manifestValue), WPEPathSafety.isSafeRelativePath(preview) {
            return preview
        }

        for candidate in ["preview.gif", "preview.jpg", "preview.png"] {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        return nil
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
    let dependencies: [String]?

    private enum CodingKeys: String, CodingKey {
        case workshopid
        case title
        case file
        case type
        case preview
        case general
        case dependencies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workshopid = try container.decodeFlexibleString(forKey: .workshopid)
        title = try container.decodeFlexibleString(forKey: .title)
        file = try container.decodeFlexibleString(forKey: .file)
        type = try container.decodeFlexibleString(forKey: .type)
        preview = try container.decodeFlexibleString(forKey: .preview)
        general = try? container.decode(DecodedGeneral.self, forKey: .general)
        dependencies = try container.decodeFlexibleStringArray(forKey: .dependencies)
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

    func decodeFlexibleStringArray(forKey key: Key) throws -> [String]? {
        guard contains(key) else { return nil }
        if let strings = try? decode([String].self, forKey: key) {
            return strings
        }
        if let ints = try? decode([Int64].self, forKey: key) {
            return ints.map(String.init)
        }
        guard var nested = try? nestedUnkeyedContainer(forKey: key) else {
            return nil
        }
        var values: [String] = []
        while !nested.isAtEnd {
            if let s = try? nested.decode(String.self) {
                values.append(s)
            } else if let i = try? nested.decode(Int64.self) {
                values.append(String(i))
            } else {
                _ = try? nested.decode(Empty.self)
            }
        }
        return values
    }

    private struct Empty: Decodable { init(from decoder: Decoder) throws {} }
}
#endif
