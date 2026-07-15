#if !LITE_BUILD
import Foundation

/// Reads scene assets in place from a packed `scene.pkg`, the way Wallpaper
/// Engine treats its mounted pak archives: parse the TOC once, then seek + read
/// individual entries on demand. No extraction, so a packed project never spawns
/// a second on-disk copy.
///
/// Holds one `FileHandle` for the provider's lifetime; `NSLock` serializes the
/// seek/read pair so concurrent asset loads can't interleave the file offset.
///
/// Memory: small/medium entries are read straight into RAM, but a large entry
/// (the 200–700 MB animated `.tex` containers) is streamed to a per-provider
/// temp file and returned memory-mapped (`.mappedIfSafe`), preserving the low-RSS
/// paging profile of the old extracted-cache path. The same staged file backs
/// `stagedURL` consumers (AVFoundation video/audio, fonts). The staging directory
/// is removed on `deinit`, but `deinit` does not run on crash / force-quit /
/// agent kill, so a launch-time sweep (`sweepStaleStagingDirectoriesAtLaunch`)
/// reclaims any per-session directory a prior session orphaned.
final class WPEPackageSceneAssetProvider: WPESceneAssetProvider, @unchecked Sendable {
    /// Entries larger than this are staged + memory-mapped instead of read into
    /// RAM, matching the historical `.mappedIfSafe` behavior for big `.tex`.
    private static let mmapThreshold: UInt64 = 64 * 1024 * 1024
    private static let copyChunkSize = 1 << 20
    /// Name prefix shared by every per-session staging directory under
    /// `NSTemporaryDirectory()`. The launch-time sweep keys off it.
    static let stagingDirectoryNamePrefix = "LiveWallpaper-WPEPkgStage-"

    private let package: WallpaperEnginePackage
    private let handle: FileHandle
    private let lock = NSLock()
    private let stagingRoot: URL
    private var stagedPaths: [String: URL] = [:]

    init(packageURL: URL) throws {
        self.stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(Self.stagingDirectoryNamePrefix)\(UUID().uuidString)", isDirectory: true)
        let handle = try FileHandle(forReadingFrom: packageURL)
        do {
            self.package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
        } catch {
            try? handle.close()
            throw error
        }
        self.handle = handle
    }

    /// Async construction seam for MainActor import/session paths. Blocking
    /// open/index work runs on `WPEPackageIndexLoader`'s utility queue and the
    /// already-positioned handle is transferred into the provider.
    static func open(
        packageURL: URL,
        limits: WallpaperEnginePackage.IndexLimits = .production
    ) async throws -> WPEPackageSceneAssetProvider {
        let prepared = try await WPEPackageIndexLoader.load(from: packageURL, limits: limits)
        do {
            try Task.checkCancellation()
        } catch {
            try? prepared.handle.close()
            throw error
        }
        return WPEPackageSceneAssetProvider(prepared: prepared)
    }

    private init(prepared: WPEPackageIndexLoader.PreparedPackage) {
        self.stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(Self.stagingDirectoryNamePrefix)\(UUID().uuidString)", isDirectory: true)
        self.package = prepared.package
        self.handle = prepared.handle
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    // MARK: - Stale staging-dir sweep

    static func staleStagingDirectoryNames(in entries: [String]) -> [String] {
        entries.filter { $0.hasPrefix(stagingDirectoryNamePrefix) }
    }

    /// Best-effort: anything that can't be listed or removed is skipped rather
    /// than throwing. Returns how many it reclaimed.
    @discardableResult
    static func sweepStaleStagingDirectories(
        in directory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        fileManager: FileManager = .default
    ) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        var removed = 0
        for name in staleStagingDirectoryNames(in: entries) {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Backstop for directories orphaned by abnormal termination, where `deinit`
    /// never ran. Call once, early in startup, before any provider is created so
    /// it can never race a live provider's staging dir.
    static func sweepStaleStagingDirectoriesAtLaunch() {
        DispatchQueue.global(qos: .utility).async {
            let removed = sweepStaleStagingDirectories()
            if removed > 0 {
                Logger.notice("Swept \(removed) stale WPE package staging dir(s)", category: .startup)
            }
        }
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
