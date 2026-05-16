#if !LITE_BUILD
import Foundation

/// Typed model of a Wallpaper Engine `project.json` manifest.
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

    /// Pulls workshop IDs out of the top-level `dependencies` array in
    /// `project.json` (the only manifest shape WPE actually emits in
    /// practice). Filters to numeric IDs in the 9–20 digit range so we
    /// don't coerce config values (e.g. volume sliders) into fake
    /// dependencies. A future revision could also walk
    /// `general.properties.<name>.value` when WPE starts using property-
    /// driven asset references — Phase 2.0.1 keeps the surface narrow.
    private static func collectDependencyWorkshopIDs(from manifest: DecodedManifest) -> [String] {
        var ids = Set<String>()
        for raw in manifest.dependencies ?? [] {
            if let id = Self.trimmed(raw), Self.looksLikeWorkshopID(id) {
                ids.insert(id)
            }
        }
        return ids.sorted()
    }

    /// Heuristic check for a Steam Workshop ID. Workshop IDs are decimal
    /// integers that fit in UInt64; treat 9–20 digits as the safe range.
    private static func looksLikeWorkshopID(_ value: String) -> Bool {
        let digits = value.count
        guard (9...20).contains(digits) else { return false }
        return value.allSatisfy(\.isNumber)
    }

    /// Recursively walks `bin/` looking for any `.dll`. WPE workshop
    /// projects ship plugins flat (`bin/plugin.dll`) but also nested by
    /// architecture (`bin/x64/`, `bin/x86/`); a flat-only check would miss
    /// the second case and let the project fall through to the dependency
    /// gate with the wrong reason.
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
        // WPE writes `dependencies` as a flexible array of either strings or
        // numbers. Coerce both into strings so the workshop-ID heuristic can
        // gate them uniformly without each call site repeating the dance.
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

    /// Decodes a JSON array whose elements may be strings or numeric IDs and
    /// returns a flat string list. Returns nil when the key is missing so
    /// callers can distinguish "not declared" from "empty array".
    func decodeFlexibleStringArray(forKey key: Key) throws -> [String]? {
        guard contains(key) else { return nil }
        if let strings = try? decode([String].self, forKey: key) {
            return strings
        }
        if let ints = try? decode([Int64].self, forKey: key) {
            return ints.map(String.init)
        }
        // Mixed: walk per-element through an unkeyed container so a single
        // numeric value doesn't poison the whole array.
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
