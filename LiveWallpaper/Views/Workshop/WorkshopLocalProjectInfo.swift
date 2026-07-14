#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation

/// WPE fields surfaced in the Installed inspector, read from the item's bundled
/// `project.json`. Purely local — never spends a Steam Web API request.
struct WPELocalProjectInfo: Sendable, Equatable {
    var cleanedDescription: String?
    var tags: [String]
    var contentRating: String?
    var sizeBytes: Int64?

    var hasContent: Bool {
        (cleanedDescription?.isEmpty == false) || !tags.isEmpty
    }
}

/// Display-only fields; `WallpaperEngineProject` (the runtime import model)
/// deliberately ignores these.
private struct WPEProjectDisplayManifest: Decodable {
    let description: String?
    let tags: [String]?
    let contentrating: String?
}

/// Resolve the item's security-scoped folder and decode its `project.json` off
/// the main actor. nil for items without a manifest (e.g. loose video / web
/// imports).
func loadWPELocalProjectInfo(for entry: WPEHistoryEntry) async -> WPELocalProjectInfo? {
    let bookmark = entry.origin.sourceFolderBookmark
    let knownSize = entry.sizeBytes
    let outcome = await Task.detached(priority: .userInitiated) { () -> (info: WPELocalProjectInfo?, freshSize: Int64?) in
        guard let folder = try? SecurityScopedBookmarkResolver.shared
            .resolve(bookmark, target: .transient).get().url
        else { return (nil, nil) }
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }

        // Walk the tree only on first open; persisted size short-circuits it.
        let size = knownSize ?? directorySize(of: folder)
        let freshSize = (knownSize == nil && size > 0) ? size : nil

        let manifestURL = folder.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(WPEProjectDisplayManifest.self, from: data)
        else {
            let info = size > 0
                ? WPELocalProjectInfo(cleanedDescription: nil, tags: [], contentRating: nil, sizeBytes: size)
                : nil
            return (info, freshSize)
        }

        let info = WPELocalProjectInfo(
            cleanedDescription: manifest.description.flatMap(strippedWPEMarkup),
            tags: manifest.tags ?? [],
            contentRating: manifest.contentrating?.trimmingCharacters(in: .whitespacesAndNewlines),
            sizeBytes: size > 0 ? size : nil
        )
        return (info, freshSize)
    }.value

    if let freshSize = outcome.freshSize {
        await SettingsManager.shared.updateWPEImportSize(
            workshopID: entry.origin.workshopID,
            sizeBytes: freshSize
        )
    }
    return outcome.info
}

/// Recursively sum every regular file under `folder`. Reads only file metadata
/// (no content), so it's cheap even for large scenes.
private func directorySize(of folder: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
    ) else { return 0 }

    var total: Int64 = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else { continue }
        total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
    return total
}

/// WPE descriptions carry Steam BBCode (`[h1]…[/h1]`, `[b]`, `[url=…]`, `[list]`
/// …). Strip the tags for a clean, native text block while keeping the words.
private func strippedWPEMarkup(_ raw: String) -> String? {
    var text = raw.replacingOccurrences(
        of: #"\[/?[^\]]*\]"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(
        of: #"[\r\n]{3,}"#, with: "\n\n", options: .regularExpression)
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

#endif
