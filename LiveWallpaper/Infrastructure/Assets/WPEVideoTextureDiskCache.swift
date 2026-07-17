#if !LITE_BUILD
import Foundation
import CryptoKit
import LiveWallpaperCore
import LiveWallpaperProWPE

/// On-disk reuse cache for the MP4 byte runs extracted from `.tex` video
/// layers, rooted at `~/Library/Caches/wpe-tex-video/`.
///
/// Layout is **per-scene, content-addressed**:
/// `wpe-tex-video/<workshopID>/<sha256>.mp4`. The workshop bucket lets launch
/// GC enumerate which files belong to scenes that are no longer installed
/// (orphans), and the content hash dedups a video that several layers — or
/// repeated extractions of the same scene — would otherwise re-stage under
/// fresh names. Local imports with no path-safe workshop ID land in the
/// `_unattributed` bucket and are always reclaimed at launch.
///
/// Lifetime: `store` hands the renderer a *leased* URL; `WPEVideoTextureSource`
/// calls `release` on invalidate instead of deleting, so the file survives for
/// reuse. Three reclamation paths keep the folder bounded: `collectOrphans` at
/// launch, `enforceSizeLimit` LRU eviction over `maxBytes`, and `purgeAll` for
/// the Settings "Clear" action. None ever evicts a leased (live) file.
///
/// Pre-refactor this folder was a UUID-named scratch dir that only self-cleaned
/// on a clean `invalidate()`; crashes/force-quits leaked files unbounded and no
/// readout counted them, so the in-app size badly under-reported `du`.
actor WPEVideoTextureDiskCache {
    static let shared = WPEVideoTextureDiskCache()

    /// Disk ceiling. The folder is a reuse cache, not a system of record (the
    /// source bytes live inside each scene's `.tex`), so a modest LRU cap is
    /// enough.
    static let defaultMaxBytes: UInt64 = 2 * 1024 * 1024 * 1024  // 2 GiB

    /// Bucket for videos whose owning scene has no path-safe workshop ID
    /// (local folder imports). Always reclaimed by launch GC — they can't be
    /// attributed to an installed scene.
    static let unattributedBucket = "_unattributed"

    private let rootURL: URL
    private let fileManager: FileManager
    private let maxBytes: UInt64

    /// Reference counts of files handed to a live `WPEVideoTextureSource`,
    /// keyed by standardized path. Never evicted or GC'd while the count is
    /// positive — the source's in-memory loader can fall back to reading the
    /// file directly, so unlinking it mid-playback would stall. Counted (not a
    /// Set) because content-addressing means a fast scene reload can have two
    /// live sources share one file; a single `release` must not free it out
    /// from under the other.
    private var leaseCounts: [String: Int] = [:]

    init(rootURL: URL? = nil, maxBytes: UInt64 = WPEVideoTextureDiskCache.defaultMaxBytes) {
        self.fileManager = .default
        self.rootURL = (rootURL ?? Self.defaultRootURL).standardizedFileURL
        self.maxBytes = maxBytes
    }

    nonisolated static var defaultRootURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wpe-tex-video", isDirectory: true)
    }

    // MARK: - Store / lease

    /// Stages `data` under the scene's bucket, content-addressed by SHA-256,
    /// and returns the leased file URL. Reuses a same-size existing file,
    /// touching its mtime so reuse refreshes LRU rank.
    func store(_ data: Data, workshopID: String) throws -> URL {
        let bucketURL = rootURL.appendingPathComponent(bucketName(for: workshopID), isDirectory: true)
        try fileManager.createDirectory(at: bucketURL, withIntermediateDirectories: true)

        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let target = bucketURL.appendingPathComponent("\(hex).mp4").standardizedFileURL

        if fileExists(target, withSize: UInt64(data.count)) {
            touch(target)
        } else {
            try data.write(to: target, options: [.atomic])
        }
        leaseCounts[target.path, default: 0] += 1
        enforceSizeLimit()
        return target
    }

    /// Balances one `store`. The file is **kept** for reuse (eligible for
    /// later LRU/GC once no live source holds it), not deleted, and stays
    /// protected until every holder has released it.
    func release(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard let count = leaseCounts[path] else { return }
        if count <= 1 {
            leaseCounts.removeValue(forKey: path)
        } else {
            leaseCounts[path] = count - 1
        }
    }

    // MARK: - Garbage collection

    /// Reclaims files that no installed/active scene references. A workshop
    /// bucket is kept only when its name is a path-safe workshop ID present in
    /// `referencedWorkshopIDs`; everything else — uninstalled-scene buckets,
    /// the `_unattributed` bucket, loose files from the legacy UUID scheme — is
    /// removed (leased files are always spared). Runs `enforceSizeLimit()`
    /// afterward. Returns freed bytes.
    @discardableResult
    func collectOrphans(referencedWorkshopIDs: Set<String>) -> UInt64 {
        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var freed: UInt64 = 0
        for child in children {
            let name = child.lastPathComponent
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let referenced = isDirectory
                && name != Self.unattributedBucket
                && WPEPathSafety.isSafeWorkshopID(name)
                && referencedWorkshopIDs.contains(name)
            if referenced || containsLeasedFile(child) { continue }

            let bytes = byteCount(at: child)
            do {
                try fileManager.removeItem(at: child)
                freed += bytes
            } catch {
                Logger.warning("WPE video cache GC: failed to remove \(name): \(error.localizedDescription)", category: .wpeRender)
            }
        }

        if freed > 0 {
            Logger.info("WPE video cache GC reclaimed \(freed) bytes from orphaned scenes", category: .wpeRender)
        }
        enforceSizeLimit()
        return freed
    }

    /// Deletes everything under the root. Unlike the automatic GC/LRU paths,
    /// this honors an explicit user "Clear" even for leased files: a live
    /// `AVPlayer` either reads from the in-memory loader (no disk handle) or
    /// holds an open fd whose inode survives the unlink, so reclaiming the
    /// directory is safe. Returns freed bytes.
    @discardableResult
    func purgeAll() -> UInt64 {
        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var freed: UInt64 = 0
        for child in children {
            let bytes = byteCount(at: child)
            do {
                try fileManager.removeItem(at: child)
                freed += bytes
            } catch {
                Logger.warning("WPE video cache purgeAll: failed to remove \(child.lastPathComponent): \(error.localizedDescription)", category: .wpeRender)
            }
        }
        if freed > 0 {
            Logger.info("WPE video cache purged \(freed) bytes", category: .wpeRender)
        }
        return freed
    }

    // MARK: - Accounting

    /// Actual on-disk footprint, summing every regular file's allocated size —
    /// the `du`-equivalent the Settings readout displays so the number matches
    /// reality rather than only the in-memory tracked set.
    func totalBytesOnDisk() -> UInt64 {
        allFiles().reduce(0) { $0 + $1.size }
    }

    func stats() -> WPEVideoCacheStats {
        let files = allFiles()
        return WPEVideoCacheStats(
            totalBytes: files.reduce(0) { $0 + $1.size },
            fileCount: files.count
        )
    }

    // MARK: - LRU eviction

    /// Evicts the least-recently-modified non-leased files until the folder is
    /// back under `maxBytes`. If only leased files remain over the cap, logs
    /// and stops — a live file is never unlinked.
    private func enforceSizeLimit() {
        let files = allFiles()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }

        let evictable = files
            .filter { !isLeased($0.url.path) }
            .sorted { $0.modified < $1.modified }

        var freed: UInt64 = 0
        for file in evictable {
            if total <= maxBytes { break }
            do {
                try fileManager.removeItem(at: file.url)
                total -= file.size
                freed += file.size
            } catch {
                Logger.warning("WPE video cache eviction: failed to remove \(file.url.lastPathComponent): \(error.localizedDescription)", category: .wpeRender)
            }
        }

        if freed > 0 {
            Logger.info("WPE video cache LRU evicted \(freed) bytes (cap \(maxBytes))", category: .wpeRender)
        }
        if total > maxBytes {
            Logger.notice("WPE video cache still over cap (\(total) > \(maxBytes)) — remaining files are in use", category: .wpeRender)
        }
    }

    // MARK: - Helpers

    private func bucketName(for workshopID: String) -> String {
        WPEPathSafety.isSafeWorkshopID(workshopID) ? workshopID : Self.unattributedBucket
    }

    private func fileExists(_ url: URL, withSize expected: UInt64) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size >= 0 else {
            return false
        }
        return UInt64(size) == expected
    }

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private struct FileRecord {
        let url: URL
        let size: UInt64
        let modified: Date
    }

    private func allFiles() -> [FileRecord] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var records: [FileRecord] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .contentModificationDateKey
            ]), values.isRegularFile == true else {
                continue
            }
            let size = UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            records.append(FileRecord(
                url: url.standardizedFileURL,
                size: size,
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return records
    }

    private func byteCount(at url: URL) -> UInt64 {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total: UInt64 = 0
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                total += UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }
            return total
        }
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    private func isLeased(_ path: String) -> Bool {
        (leaseCounts[path] ?? 0) > 0
    }

    /// True if `url` is a leased file or a directory containing one.
    private func containsLeasedFile(_ url: URL) -> Bool {
        guard !leaseCounts.isEmpty else { return false }
        let path = url.standardizedFileURL.path
        if isLeased(path) { return true }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return leaseCounts.keys.contains { $0.hasPrefix(prefix) }
    }
}

/// Disk-usage snapshot of the WPE video-texture cache, surfaced in Settings.
struct WPEVideoCacheStats: Sendable, Equatable {
    let totalBytes: UInt64
    let fileCount: Int
}
#endif
