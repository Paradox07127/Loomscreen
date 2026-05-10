import Foundation
import CryptoKit

/// Manages on-disk caches of extracted Wallpaper Engine `scene.pkg` archives
/// under `~/Library/Application Support/LiveWallpaper/wpe-cache/<workshopID>/`.
/// Idempotent: a sibling `manifest.json` records the source pkg's
/// `(size, mtime)` fingerprint and lets repeated imports skip re-extraction.
actor WallpaperEngineCache {
    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil) {
        self.fileManager = .default
        if let rootURL {
            self.rootURL = rootURL
            return
        }

        if let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            self.rootURL = applicationSupport
                .appendingPathComponent("LiveWallpaper", isDirectory: true)
                .appendingPathComponent("wpe-cache", isDirectory: true)
        } else {
            self.rootURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/LiveWallpaper/wpe-cache", isDirectory: true)
        }
    }

    func ensureExtracted(workshopID: String, sourcePkgURL: URL) async throws -> URL {
        let cacheURL = try cacheDirectory(for: workshopID)
        let fingerprint = try fingerprint(for: sourcePkgURL)

        if let manifest = readManifest(in: cacheURL),
           manifest.fingerprint == fingerprint,
           cacheHasPayload(cacheURL) {
            Logger.info("WPE cache hit for workshop \(workshopID)", category: .screenManager)
            return cacheURL
        }

        Logger.info("WPE cache extracting workshop \(workshopID)", category: .screenManager)
        do {
            // Streaming parse + extract: reads the index from the pkg's
            // header bytes, then per-entry seeks the same handle. Memory
            // peak is bounded by the 1 MiB chunk inside the package.
            let handle = try FileHandle(forReadingFrom: sourcePkgURL)
            defer { try? handle.close() }

            let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
            try package.extractAll(streamingFrom: handle, to: cacheURL)
            try writeManifest(
                Manifest(fingerprint: fingerprint, extractedAt: Date().timeIntervalSince1970),
                in: cacheURL
            )
            Logger.info("WPE cache extracted workshop \(workshopID)", category: .screenManager)
            return cacheURL
        } catch let error as WPECacheError {
            Logger.error("WPE extraction failed: \(error.localizedDescription)", category: .screenManager)
            throw error
        } catch {
            Logger.error("WPE extraction failed: \(error.localizedDescription)", category: .screenManager)
            throw WPECacheError.extractionFailed(String(describing: error))
        }
    }

    /// Workshop IDs whose extracted payload currently lives under the cache
    /// root. Used by the import service to flag missing dependencies before
    /// mounting an unrenderable scene. Filters out subdirectories whose name
    /// fails the workshop-id safety check (mirrors `stats()`).
    func listAvailableWorkshopIDs() -> Set<String> {
        guard fileManager.fileExists(atPath: rootURL.path),
              let children = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var ids: Set<String> = []
        for child in children {
            let id = child.lastPathComponent
            guard WPEPathSafety.isSafeWorkshopID(id) else { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if cacheHasPayload(child) {
                ids.insert(id)
            }
        }
        return ids
    }

    func purge(workshopID: String) throws {
        let cacheURL = try cacheDirectory(for: workshopID)
        guard fileManager.fileExists(atPath: cacheURL.path) else { return }
        try fileManager.removeItem(at: cacheURL)
        Logger.info("WPE cache purged workshop \(workshopID)", category: .screenManager)
    }

    /// Aggregate stats over every per-workshop subdirectory under the root.
    /// Subdirectories whose name fails `isSafeWorkshopID` are skipped — they
    /// can't have been written by us, so we don't account for them.
    func stats() -> WPECacheStats {
        guard fileManager.fileExists(atPath: rootURL.path),
              let children = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return WPECacheStats(rootURL: rootURL, totalBytes: 0, entries: [])
        }

        var entries: [WPECacheStats.Entry] = []
        var totalBytes: UInt64 = 0

        for child in children {
            let workshopID = child.lastPathComponent
            guard WPEPathSafety.isSafeWorkshopID(workshopID) else { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

            let bytes = directoryByteCount(at: child)
            let lastUsed = lastUsedDate(in: child)
            entries.append(WPECacheStats.Entry(workshopID: workshopID, sizeBytes: bytes, lastUsed: lastUsed))
            totalBytes += bytes
        }

        entries.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        return WPECacheStats(rootURL: rootURL, totalBytes: totalBytes, entries: entries)
    }

    /// Wipes every per-workshop subdirectory under the root (manifest + payloads).
    /// Returns the byte count freed for caller reporting; never throws on a
    /// missing root (idempotent).
    @discardableResult
    func purgeAll() -> UInt64 {
        guard fileManager.fileExists(atPath: rootURL.path),
              let children = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return 0
        }

        var freed: UInt64 = 0
        for child in children {
            let workshopID = child.lastPathComponent
            guard WPEPathSafety.isSafeWorkshopID(workshopID) else { continue }
            let bytes = directoryByteCount(at: child)
            do {
                try fileManager.removeItem(at: child)
                freed += bytes
            } catch {
                Logger.warning("WPE cache purgeAll: failed to remove \(workshopID): \(error.localizedDescription)", category: .screenManager)
            }
        }
        Logger.info("WPE cache purged all (\(freed) bytes freed)", category: .screenManager)
        return freed
    }

    /// Removes per-workshop directories whose `lastUsed` (manifest extractedAt
    /// or directory mtime) is older than `cutoff`. Returns the byte count freed.
    @discardableResult
    func purgeOlderThan(_ cutoff: Date) -> UInt64 {
        let snapshot = stats()
        var freed: UInt64 = 0
        for entry in snapshot.entries {
            guard let lastUsed = entry.lastUsed, lastUsed < cutoff else { continue }
            do {
                try purge(workshopID: entry.workshopID)
                freed += entry.sizeBytes
            } catch {
                Logger.warning("WPE cache purgeOlderThan: failed to purge \(entry.workshopID): \(error.localizedDescription)", category: .screenManager)
            }
        }
        Logger.info("WPE cache purgeOlderThan(\(cutoff)) freed \(freed) bytes", category: .screenManager)
        return freed
    }

    private func directoryByteCount(at url: URL) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += UInt64(size)
        }
        return total
    }

    private func lastUsedDate(in cacheURL: URL) -> Date? {
        if let manifest = readManifest(in: cacheURL) {
            return Date(timeIntervalSince1970: manifest.extractedAt)
        }
        return (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func cacheDirectory(for workshopID: String) throws -> URL {
        guard WPEPathSafety.isSafeWorkshopID(workshopID) else {
            throw WPECacheError.invalidWorkshopID(workshopID)
        }
        let root = rootURL.standardizedFileURL
        let candidate = root
            .appendingPathComponent(workshopID, isDirectory: true)
            .standardizedFileURL
        let canonicalRoot = root.resolvingSymlinksInPath()
        let canonicalCandidate = candidate.resolvingSymlinksInPath()
        guard WPEPathSafety.contains(canonicalCandidate, in: canonicalRoot) else {
            throw WPECacheError.invalidWorkshopID(workshopID)
        }
        return candidate
    }

    private func cacheHasPayload(_ cacheURL: URL) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: cacheURL.path) else {
            return false
        }
        return entries.contains { $0 != "manifest.json" }
    }

    private func manifestURL(in cacheURL: URL) -> URL {
        cacheURL.appendingPathComponent("manifest.json")
    }

    /// Streaming fingerprint: hashes the source pkg in 64 KiB chunks instead
    /// of mapping the entire file. Keeps idempotency guarantees (size + mtime
    /// + sha256) while bounding peak memory regardless of pkg size.
    private func fingerprint(for sourcePkgURL: URL) throws -> Fingerprint {
        do {
            let values = try sourcePkgURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values.fileSize,
                  size >= 0,
                  let mtime = values.contentModificationDate?.timeIntervalSince1970 else {
                throw WPECacheError.pkgUnreadable("Missing file metadata")
            }
            let sha = try Self.streamingSHA256Hex(of: sourcePkgURL)
            return Fingerprint(size: UInt64(size), mtime: mtime, sha256: sha)
        } catch let error as WPECacheError {
            throw error
        } catch {
            throw WPECacheError.pkgUnreadable(error.localizedDescription)
        }
    }

    private static func streamingSHA256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 64 * 1024
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func readManifest(in cacheURL: URL) -> Manifest? {
        let url = manifestURL(in: cacheURL)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            Logger.warning("WPE cache manifest unreadable: \(error.localizedDescription)", category: .screenManager)
            return nil
        }
    }

    private func writeManifest(_ manifest: Manifest, in cacheURL: URL) throws {
        try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(in: cacheURL), options: .atomic)
    }
}

private struct Manifest: Codable, Equatable, Sendable {
    let fingerprint: Fingerprint
    let extractedAt: Double
}

private struct Fingerprint: Codable, Equatable, Sendable {
    let size: UInt64
    let mtime: Double
    let sha256: String
}

enum WPECacheError: Error, Equatable, Sendable {
    case invalidWorkshopID(String)
    case pkgUnreadable(String)
    case extractionFailed(String)
}

/// Disk-usage snapshot of the WPE cache, sorted most-recently-used first.
/// Surfaced to the cache management UI in Settings.
struct WPECacheStats: Sendable, Equatable {
    struct Entry: Sendable, Equatable, Identifiable {
        let workshopID: String
        let sizeBytes: UInt64
        let lastUsed: Date?

        var id: String { workshopID }
    }

    let rootURL: URL
    let totalBytes: UInt64
    let entries: [Entry]
}
