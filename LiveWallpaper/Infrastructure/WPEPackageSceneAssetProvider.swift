#if !LITE_BUILD
import Foundation

/// Reads scene assets in place from a packed `scene.pkg`, the way Wallpaper
/// Engine treats its mounted pak archives: parse the table of contents once,
/// then seek + read individual entries on demand. No extraction, so a packed
/// project never spawns a second on-disk copy.
///
/// Holds one `FileHandle` for the provider's lifetime; `NSLock` serializes the
/// seek/read pair so concurrent asset loads can't interleave the file offset.
final class WPEPackageSceneAssetProvider: WPESceneAssetProvider, @unchecked Sendable {
    private let packageURL: URL
    private let package: WallpaperEnginePackage
    private let handle: FileHandle
    private let lock = NSLock()
    private let stager: WPEPackageEntryDiskStager
    /// Stable identity for staged-file content addressing. Two providers over
    /// the same package path share staged temporaries.
    private let stagingNamespace: String

    init(packageURL: URL, stager: WPEPackageEntryDiskStager = .shared) throws {
        self.packageURL = packageURL
        self.stager = stager
        self.stagingNamespace = packageURL.standardizedFileURL.path
        let handle = try FileHandle(forReadingFrom: packageURL)
        do {
            self.package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
        } catch {
            try? handle.close()
            throw error
        }
        self.handle = handle
    }

    deinit {
        try? handle.close()
    }

    func data(atRelativePath relativePath: String) throws -> Data {
        let entry = try packageEntry(for: relativePath)
        lock.lock()
        defer { lock.unlock() }
        do {
            return try package.readEntry(entry, from: handle)
        } catch {
            throw WPESceneAssetProviderError.unreadable(relativePath)
        }
    }

    func stagedURL(atRelativePath relativePath: String, purpose: WPESceneAssetURLPurpose) throws -> WPEStagedAssetURL {
        let entry = try packageEntry(for: relativePath)
        let key = "\(stagingNamespace)#\(entry.name)@\(entry.dataOffset):\(entry.dataSize)"
        return try stager.stagedURL(forKey: key, suggestedName: entry.name) { [weak self] in
            guard let self else { throw WPESceneAssetProviderError.unreadable(relativePath) }
            self.lock.lock()
            defer { self.lock.unlock() }
            do {
                return try self.package.readEntry(entry, from: self.handle)
            } catch {
                throw WPESceneAssetProviderError.unreadable(relativePath)
            }
        }
    }

    func exists(atRelativePath relativePath: String) -> Bool {
        (try? packageEntry(for: relativePath)) != nil
    }

    var entryNames: [String] {
        package.entries.map(\.name).sorted()
    }

    private func packageEntry(for relativePath: String) throws -> WallpaperEnginePackage.Entry {
        guard let lookupName = WallpaperEnginePackage.canonicalLookupName(relativePath) else {
            throw WPESceneAssetProviderError.invalidRelativePath(relativePath)
        }
        guard let entry = package.entry(named: lookupName) else {
            throw WPESceneAssetProviderError.fileMissing(relativePath)
        }
        return entry
    }
}
#endif
