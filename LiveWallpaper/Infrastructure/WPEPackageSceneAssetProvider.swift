#if !LITE_BUILD
import Foundation

/// Reads scene assets in place from a packed `scene.pkg`, the way Wallpaper
/// Engine treats its mounted pak archives: parse the table of contents once,
/// then seek + read individual entries on demand. No extraction, so a packed
/// project never spawns a second on-disk copy.
///
/// Holds one `FileHandle` for the provider's lifetime; `NSLock` serializes the
/// seek/read pair so concurrent asset loads can't interleave the file offset.
///
/// Memory: small/medium entries are read straight into RAM, but a large entry
/// (the 200–700 MB animated `.tex` containers) is instead streamed to a
/// per-provider temporary file and returned memory-mapped (`.mappedIfSafe`), so
/// the low-RSS paging profile of the old extracted-cache path is preserved
/// rather than fully materializing the entry in resident memory. The same
/// staged file backs `stagedURL` consumers (AVFoundation video/audio, fonts).
/// The staging directory's lifetime equals the scene session — removed on
/// deinit, so staged files never outlive the wallpaper that needed them.
final class WPEPackageSceneAssetProvider: WPESceneAssetProvider, @unchecked Sendable {
    /// Entries larger than this are staged + memory-mapped instead of read into
    /// RAM, matching the historical `.mappedIfSafe` behavior for big `.tex`.
    private static let mmapThreshold: UInt64 = 64 * 1024 * 1024
    private static let copyChunkSize = 1 << 20

    private let package: WallpaperEnginePackage
    private let handle: FileHandle
    private let lock = NSLock()
    /// Per-provider staging directory (lazily created); removed on deinit.
    private let stagingRoot: URL
    private var stagedPaths: [String: URL] = [:]

    init(packageURL: URL) throws {
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
        if entry.dataSize > Self.mmapThreshold {
            // Big entry: stage once, then memory-map — never resident in full.
            let url = try stageEntryLocked(entry, relativePath: relativePath)
            do {
                return try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw WPESceneAssetProviderError.unreadable(relativePath)
            }
        }
        do {
            return try package.readEntry(entry, from: handle)
        } catch {
            throw WPESceneAssetProviderError.unreadable(relativePath)
        }
    }

    func stagedURL(atRelativePath relativePath: String) throws -> URL {
        let entry = try packageEntry(for: relativePath)
        lock.lock()
        defer { lock.unlock() }
        return try stageEntryLocked(entry, relativePath: relativePath)
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

    /// Streams an entry's bytes to a staged temp file (chunked, so a large entry
    /// never fully materializes in RAM) and memoizes it. Caller holds `lock`.
    private func stageEntryLocked(_ entry: WallpaperEnginePackage.Entry, relativePath: String) throws -> URL {
        if let existing = stagedPaths[entry.name],
           FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let safeName = (entry.name as NSString).lastPathComponent
            let target = stagingRoot.appendingPathComponent(
                "\(stagedPaths.count)-\(safeName.isEmpty ? "asset" : safeName)",
                isDirectory: false
            )
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let writer = try FileHandle(forWritingTo: target)
            do {
                try handle.seek(toOffset: package.dataStart + entry.dataOffset)
                var remaining = entry.dataSize
                while remaining > 0 {
                    let toRead = Int(min(UInt64(Self.copyChunkSize), remaining))
                    guard let chunk = try handle.read(upToCount: toRead), chunk.count == toRead else {
                        throw WPESceneAssetProviderError.unreadable(relativePath)
                    }
                    try writer.write(contentsOf: chunk)
                    remaining -= UInt64(chunk.count)
                }
                try writer.close()
            } catch {
                try? writer.close()
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            stagedPaths[entry.name] = target
            return target
        } catch let error as WPESceneAssetProviderError {
            throw error
        } catch {
            throw WPESceneAssetProviderError.stagingUnavailable(relativePath)
        }
    }
}
#endif
