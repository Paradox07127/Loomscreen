#if !LITE_BUILD
import Foundation

/// Materializes individual `scene.pkg` entries to temporary files for the few
/// consumers that genuinely require a file URL (AVFoundation video/audio, some
/// ImageIO paths). Content-addressed by entry identity so repeated requests
/// reuse one staged file; reference-counted so a file is only eligible for
/// eviction once every lease is released; bounded by a soft byte cap with LRU
/// eviction of unreferenced files.
///
/// Directory-backed scenes never touch this — they expose project files
/// directly. It exists solely so packed scenes stay memory- and disk-bounded.
final class WPEPackageEntryDiskStager: @unchecked Sendable {
    static let shared = WPEPackageEntryDiskStager()

    private struct Staged {
        let url: URL
        let size: UInt64
        var refCount: Int
        var lastUsedTick: UInt64
    }

    private let maxBytes: UInt64
    private let stagingRoot: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var entries: [String: Staged] = [:]
    private var tick: UInt64 = 0

    init(maxBytes: UInt64 = 512 * 1024 * 1024, fileManager: FileManager = .default) {
        self.maxBytes = maxBytes
        self.fileManager = fileManager
        self.stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LiveWallpaper-WPEPackageStage", isDirectory: true)
    }

    /// Returns a staged file URL for `key`, producing the bytes via `produce`
    /// only on a cache miss. The returned `WPEStagedAssetURL` holds one lease;
    /// `release()` drops it and makes the file eligible for eviction.
    func stagedURL(
        forKey key: String,
        suggestedName: String,
        produce: () throws -> Data
    ) throws -> WPEStagedAssetURL {
        lock.lock()
        if var existing = entries[key], fileManager.fileExists(atPath: existing.url.path) {
            existing.refCount += 1
            tick &+= 1
            existing.lastUsedTick = tick
            entries[key] = existing
            lock.unlock()
            return makeLease(key: key, url: existing.url)
        }
        // Drop a stale record whose backing file vanished.
        entries[key] = nil
        lock.unlock()

        let data = try produce()

        lock.lock()
        defer { lock.unlock() }
        // Another caller may have staged the same key while we produced.
        if var existing = entries[key], fileManager.fileExists(atPath: existing.url.path) {
            existing.refCount += 1
            tick &+= 1
            existing.lastUsedTick = tick
            entries[key] = existing
            return makeLease(key: key, url: existing.url)
        }

        let url = try writeStagedFile(data: data, suggestedName: suggestedName)
        tick &+= 1
        entries[key] = Staged(url: url, size: UInt64(data.count), refCount: 1, lastUsedTick: tick)
        evictIfNeeded(protecting: key)
        return makeLease(key: key, url: url)
    }

    private func makeLease(key: String, url: URL) -> WPEStagedAssetURL {
        WPEStagedAssetURL(url: url) { [weak self] in
            self?.release(key: key)
        }
    }

    private func release(key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var staged = entries[key] else { return }
        staged.refCount = max(0, staged.refCount - 1)
        entries[key] = staged
        evictIfNeeded(protecting: nil)
    }

    /// Evicts unreferenced staged files (oldest first) until total bytes fall
    /// under the cap. `protecting` is never evicted even if over budget.
    private func evictIfNeeded(protecting protectedKey: String?) {
        var total = entries.values.reduce(UInt64(0)) { $0 + $1.size }
        guard total > maxBytes else { return }
        let evictable = entries
            .filter { $0.value.refCount == 0 && $0.key != protectedKey }
            .sorted { $0.value.lastUsedTick < $1.value.lastUsedTick }
        for (key, staged) in evictable {
            try? fileManager.removeItem(at: staged.url)
            entries[key] = nil
            total = total >= staged.size ? total - staged.size : 0
            if total <= maxBytes { break }
        }
    }

    private func writeStagedFile(data: Data, suggestedName: String) throws -> URL {
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let ext = (suggestedName as NSString).pathExtension
        var name = "\(tick)-\(UInt64(bitPattern: Int64(suggestedName.hashValue)))"
        if !ext.isEmpty { name += ".\(ext)" }
        let url = stagingRoot.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: [.atomic])
        return url
    }
}
#endif
