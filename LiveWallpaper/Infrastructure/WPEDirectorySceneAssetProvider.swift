#if !LITE_BUILD
import Foundation

/// Reads scene assets from a directory of files — the legacy extracted
/// `wpe-cache/<id>` root or a folder-import source. Path safety mirrors the
/// historical resolver exactly (`WPEPathSafety.strictResourceURL`), and reads
/// use `.mappedIfSafe` so large `.tex` containers keep their low-RSS paging
/// behavior.
struct WPEDirectorySceneAssetProvider: WPESceneAssetProvider {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Computed rather than stored so the struct stays `Sendable` (`FileManager`
    /// is not `Sendable`), mirroring `SceneResourceResolver`.
    private var fileManager: FileManager { .default }

    func data(atRelativePath relativePath: String) throws -> Data {
        let url = try strictURL(for: relativePath)
        guard isRegularFile(url) else {
            throw WPESceneAssetProviderError.fileMissing(relativePath)
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw WPESceneAssetProviderError.unreadable(relativePath)
        }
    }

    func stagedURL(atRelativePath relativePath: String) throws -> URL {
        let url = try strictURL(for: relativePath)
        guard isRegularFile(url) else {
            throw WPESceneAssetProviderError.fileMissing(relativePath)
        }
        // The project file itself satisfies the consumer — no copy.
        return url
    }

    func exists(atRelativePath relativePath: String) -> Bool {
        guard let url = try? strictURL(for: relativePath) else { return false }
        return isRegularFile(url)
    }

    var entryNames: [String] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let rootPrefix = rootURL.path + "/"
        var names: [String] = []
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            let standardized = fileURL.standardizedFileURL.path
            guard standardized.hasPrefix(rootPrefix) else { continue }
            names.append(String(standardized.dropFirst(rootPrefix.count)))
        }
        return names.sorted()
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func strictURL(for relativePath: String) throws -> URL {
        guard let url = WPEPathSafety.strictResourceURL(root: rootURL, relativePath: relativePath) else {
            throw WPESceneAssetProviderError.invalidRelativePath(relativePath)
        }
        return url
    }
}
#endif
