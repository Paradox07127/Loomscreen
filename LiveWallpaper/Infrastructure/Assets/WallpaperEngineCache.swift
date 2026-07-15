#if !LITE_BUILD
import Foundation

/// Read-only custodian of the retired extraction cache under
/// `~/Library/Application Support/LiveWallpaper/wpe-cache/<workshopID>/`.
/// Nothing writes it any more — imports read `scene.pkg` in place — but old
/// installs still have directories (and their `manifest.json` sidecars) on
/// disk, so this enumerates, measures, and reclaims them.
actor WallpaperEngineCache {
    /// Shared instance over the default cache root. Tests that need a custom root
    /// still construct directly via `init(rootURL:)`.
    static let shared = WallpaperEngineCache()

    private let rootURL: URL
    private let fileManager: FileManager

    /// `nonisolated` so non-actor callers (e.g. a "Show in Finder" settings
    /// button) can resolve the cache root synchronously.
    nonisolated static var defaultRootURL: URL {
        if let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            return applicationSupport
                .appendingPathComponent("LiveWallpaper", isDirectory: true)
                .appendingPathComponent("wpe-cache", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/LiveWallpaper/wpe-cache", isDirectory: true)
    }

    init(rootURL: URL? = nil) {
        self.fileManager = .default
        self.rootURL = rootURL ?? Self.defaultRootURL
    }

    /// Workshop IDs whose extracted payload currently lives under the cache root.
    func listAvailableWorkshopIDs() -> Set<String> {
        listWorkshopIDs(requireCompletedManifest: false)
    }

    /// Workshop IDs whose cache payload also has a readable completion manifest
    /// (written only after a successful extract/mirror). Use this to gate
    /// DESTRUCTIVE source-archive cleanup so a half-extracted cache never lets a
    /// caller trash the only good copy.
    func listCompletedWorkshopIDs() -> Set<String> {
        listWorkshopIDs(requireCompletedManifest: true)
    }

    private func listWorkshopIDs(requireCompletedManifest: Bool) -> Set<String> {
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
            guard WPEPathSafety.isSafeWorkshopID(id), !isExtractionSidecar(id) else { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if cacheHasPayload(child), !requireCompletedManifest || readManifest(in: child) != nil {
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

    /// Permanently removes (not Trash) the per-workshop cache directory. Under
    /// App Sandbox `trashItem` on a container-internal path lands in the
    /// *container's* hidden `.Trash` (`…/Containers/<id>/Data/.Trash/`), which is
    /// invisible in Finder and never frees space — so a "move to Trash" delete
    /// looked like a no-op to the user. The target goes through the same
    /// `cacheDirectory` validation (`isSafeWorkshopID` + containment-within-
    /// `wpe-cache`), so it can only resolve to `…/wpe-cache/<id>/`.
    @discardableResult
    func deleteFiles(workshopID: String) throws -> Bool {
        let cacheURL = try cacheDirectory(for: workshopID)
        guard fileManager.fileExists(atPath: cacheURL.path) else { return false }
        try fileManager.removeItem(at: cacheURL)
        Logger.info("WPE cache deleted for workshop \(workshopID)", category: .screenManager)
        return true
    }

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
            guard WPEPathSafety.isSafeWorkshopID(workshopID), !isExtractionSidecar(workshopID) else { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

            let bytes = directoryByteCount(at: child)
            let lastUsed = lastUsedDate(in: child)
            entries.append(WPECacheStats.Entry(workshopID: workshopID, sizeBytes: bytes, lastUsed: lastUsed))
            totalBytes += bytes
        }

        entries.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        return WPECacheStats(rootURL: rootURL, totalBytes: totalBytes, entries: entries)
    }

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
            guard WPEPathSafety.isSafeWorkshopID(workshopID), !isExtractionSidecar(workshopID) else { continue }
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

    /// `lastUsed` = manifest extractedAt or directory mtime. `keepingIDs` (the
    /// reachable set: applied / bookmarked / recent) are never removed, so a
    /// scene the user still uses isn't treated as "unused" just because its
    /// extraction is old.
    @discardableResult
    func purgeOlderThan(_ cutoff: Date, keepingIDs: Set<String> = []) -> UInt64 {
        let snapshot = stats()
        var freed: UInt64 = 0
        for entry in snapshot.entries {
            guard !keepingIDs.contains(entry.workshopID) else { continue }
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

    /// `.inflight`/`.replaced` are transient extraction sidecars
    /// (`WallpaperEnginePackage.extractAll`); they pass `isSafeWorkshopID` but
    /// are not finished per-workshop caches, so normal enumeration skips them —
    /// reporting or reclaiming one could corrupt an in-flight extraction. The
    /// launch GC additionally sweeps *stale* (crash-leftover) sidecars by age.
    private func isExtractionSidecar(_ name: String) -> Bool {
        name.hasSuffix(".inflight") || name.hasSuffix(".replaced")
    }

    /// Any sidecar older than this is a crash leftover, never an active
    /// extraction (a streamed extract finishes in seconds-to-minutes), so it is
    /// safe for the launch GC to reclaim.
    private static let staleSidecarMaxAge: TimeInterval = 3600

    /// Launch-time orphan GC: hard-deletes every per-workshop cache directory
    /// whose id is **not** in `keepIDs` (the reachable set: applied configs,
    /// bookmarks, recent imports, and their dependencies). Also reclaims stale
    /// extraction sidecars (crash leftovers older than `staleSidecarMaxAge`)
    /// while sparing young ones that may be live. An unreferenced scene is also
    /// unreachable from the UI, so dropping it loses nothing actionable.
    @discardableResult
    func collectOrphans(keepIDs: Set<String>) -> UInt64 {
        guard fileManager.fileExists(atPath: rootURL.path),
              let children = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return 0
        }

        let sidecarCutoff = Date().addingTimeInterval(-Self.staleSidecarMaxAge)
        var freed: UInt64 = 0
        for child in children {
            let id = child.lastPathComponent

            if isExtractionSidecar(id) {
                // Reclaim only sidecars old enough to be a guaranteed leftover;
                // a young one may belong to an extraction in progress right now.
                guard let mtime = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime < sidecarCutoff else { continue }
                let bytes = directoryByteCount(at: child)
                do {
                    try fileManager.removeItem(at: child)
                    freed += bytes
                } catch {
                    Logger.warning("WPE cache orphan GC: failed to remove stale sidecar \(id): \(error.localizedDescription)", category: .screenManager)
                }
                continue
            }

            guard WPEPathSafety.isSafeWorkshopID(id) else { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if keepIDs.contains(id) { continue }

            let bytes = directoryByteCount(at: child)
            do {
                try fileManager.removeItem(at: child)
                freed += bytes
            } catch {
                Logger.warning("WPE cache orphan GC: failed to remove \(id): \(error.localizedDescription)", category: .screenManager)
            }
        }
        if freed > 0 {
            Logger.info("WPE cache orphan GC reclaimed \(freed) bytes from unreferenced scenes / stale sidecars", category: .screenManager)
        }
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
}

/// Decode-only: nothing writes a manifest since extraction was retired, but old
/// installs still have them on disk and `readManifest` gates completion + the
/// `lastUsed` sort on parsing them. Both fields must keep matching the historical
/// JSON or every legacy cache silently reads back as incomplete.
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
}

/// Disk-usage snapshot of the WPE cache, sorted most-recently-used first.
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
#endif
