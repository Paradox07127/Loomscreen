#if !LITE_BUILD
import Foundation

/// Reads scene assets in place from a packed `scene.pkg`, the way Wallpaper
/// Engine treats its mounted pak archives: parse the table of contents once,
/// then seek + read individual entries on demand. No extraction, so a packed
/// project never spawns a second on-disk copy.
///
/// Holds one `FileHandle` for the provider's lifetime; `NSLock` serializes the
/// seek/read pair so concurrent asset loads can't interleave the file offset.
/// The few consumers that require a file URL (AVFoundation video/audio, some
/// ImageIO/Core Text paths) get an entry staged into a per-provider temporary
/// directory whose lifetime equals the scene session — cleaned up on deinit, so
/// staged files never outlive the wallpaper that needed them.
final class WPEPackageSceneAssetProvider: WPESceneAssetProvider, @unchecked Sendable {
    private let packageURL: URL
    private let package: WallpaperEnginePackage
    private let handle: FileHandle
    private let lock = NSLock()
    /// Per-provider staging directory (lazily created); removed on deinit.
    private let stagingRoot: URL
    private var stagedPaths: [String: URL] = [:]

    init(packageURL: URL) throws {
        self.packageURL = packageURL
        self.stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LiveWallpaper-WPEPkgStage-\(UUID().uuidString)", isDirectory: true)
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
        try? FileManager.default.removeItem(at: stagingRoot)
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
        lock.lock()
        defer { lock.unlock() }
        if let existing = stagedPaths[entry.name],
           FileManager.default.fileExists(atPath: existing.path) {
            return WPEStagedAssetURL(url: existing)
        }
        let data: Data
        do {
            data = try package.readEntry(entry, from: handle)
        } catch {
            throw WPESceneAssetProviderError.unreadable(relativePath)
        }
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let safeName = (entry.name as NSString).lastPathComponent
            let target = stagingRoot.appendingPathComponent(
                "\(stagedPaths.count)-\(safeName.isEmpty ? "asset" : safeName)",
                isDirectory: false
            )
            try data.write(to: target, options: [.atomic])
            stagedPaths[entry.name] = target
            return WPEStagedAssetURL(url: target)
        } catch {
            throw WPESceneAssetProviderError.stagingUnavailable(relativePath)
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
