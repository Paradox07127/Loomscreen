#if !LITE_BUILD
import Foundation
import CryptoKit

/// Caches extracted `scene.pkg` archives under
/// `~/Library/Application Support/LiveWallpaper/wpe-cache/<workshopID>/`.
/// Idempotent: a sibling `manifest.json` records the source pkg's
/// `(size, mtime)` fingerprint and lets repeated imports skip re-extraction.
actor WallpaperEngineCache {
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
        } catch let error as WPEPackageError {
            // A bad/absent PKGV header almost always means SteamCMD landed a
            // truncated/placeholder `scene.pkg` (partial download, entitlement/
            // region issue) rather than a real package. Dump head bytes + size so
            // a recurrence is unambiguous (truncated PKGV vs HTML error page vs a
            // new magic) — a valid scene.pkg begins with U32 length 8 + "PKGV00NN".
            Logger.error("WPE extraction failed: \(error) — \(Self.headDescription(of: sourcePkgURL))", category: .screenManager)
            switch error {
            case .invalidMagic, .truncatedHeader:
                throw WPECacheError.extractionFailed(String(localized: "The downloaded file isn't a valid Wallpaper Engine package — the SteamCMD download was likely incomplete. Try downloading it again.", comment: "WPE extraction failed: scene.pkg has no valid PKGV header, usually a partial download."))
            default:
                throw WPECacheError.extractionFailed(String(describing: error))
            }
        } catch {
            Logger.error("WPE extraction failed: \(error.localizedDescription)", category: .screenManager)
            throw WPECacheError.extractionFailed(String(describing: error))
        }
    }

    /// Diagnostic for a parse failure: a real `scene.pkg` starts `08 00 00 00
    /// "PKGV00NN"`; a partial download is short, an HTML error page starts `3c`
    /// (`<`). Best-effort; never throws.
    private static func headDescription(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "head: <unreadable>" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        let hex = head.map { String(format: "%02x", $0) }.joined(separator: " ")
        let ascii = String(head.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return "size: \(size)B, head: [\(hex)] \"\(ascii)\""
    }

    func ensureMirroredDirectory(workshopID: String, sourceFolderURL: URL) async throws -> URL {
        let cacheURL = try cacheDirectory(for: workshopID)
        // Defense-in-depth: if the "source" resolves to our own cache directory
        // (e.g. a library root misconfigured to point at wpe-cache), the mirror
        // below would `removeItem(cacheURL)` and wipe the payload it reads from.
        // Never self-destruct — return the existing cache untouched.
        let canonicalSource = sourceFolderURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalCache = cacheURL.standardizedFileURL.resolvingSymlinksInPath()
        if canonicalSource == canonicalCache {
            guard cacheHasPayload(cacheURL) else {
                throw WPECacheError.extractionFailed("Source folder is the cache destination and has no payload")
            }
            Logger.info("WPE cache self-mirror skipped for workshop \(workshopID)", category: .screenManager)
            return cacheURL
        }
        let fingerprint = try fingerprint(forDirectory: sourceFolderURL)

        if let manifest = readManifest(in: cacheURL),
           manifest.fingerprint == fingerprint,
           cacheHasPayload(cacheURL) {
            Logger.info("WPE cache hit for unpacked workshop \(workshopID)", category: .screenManager)
            return cacheURL
        }

        Logger.info("WPE cache mirroring unpacked workshop \(workshopID)", category: .screenManager)
        do {
            if fileManager.fileExists(atPath: cacheURL.path) {
                try fileManager.removeItem(at: cacheURL)
            }
            try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
            let children = try fileManager.contentsOfDirectory(
                at: sourceFolderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey])
                let destination = cacheURL.appendingPathComponent(
                    child.lastPathComponent,
                    isDirectory: values.isDirectory == true
                )
                try fileManager.copyItem(at: child, to: destination)
            }
            try writeManifest(
                Manifest(fingerprint: fingerprint, extractedAt: Date().timeIntervalSince1970),
                in: cacheURL
            )
            Logger.info("WPE cache mirrored unpacked workshop \(workshopID)", category: .screenManager)
            return cacheURL
        } catch let error as WPECacheError {
            Logger.error("WPE directory mirror failed: \(error.localizedDescription)", category: .screenManager)
            throw error
        } catch {
            Logger.error("WPE directory mirror failed: \(error.localizedDescription)", category: .screenManager)
            throw WPECacheError.extractionFailed(String(describing: error))
        }
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

    /// Streaming fingerprint: hashes the source pkg in 64 KiB chunks instead of mapping the entire file.
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

    private func fingerprint(forDirectory sourceFolderURL: URL) throws -> Fingerprint {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceFolderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WPECacheError.pkgUnreadable("Source folder is missing")
        }

        let root = sourceFolderURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: []
        ) else {
            throw WPECacheError.pkgUnreadable("Cannot enumerate source folder")
        }

        var entries: [(relativePath: String, url: URL, values: URLResourceValues)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            if values.isSymbolicLink == true {
                throw WPECacheError.extractionFailed("Unpacked WPE project contains a symbolic link: \(url.lastPathComponent)")
            }
            let absolute = url.standardizedFileURL.resolvingSymlinksInPath().path
            let rootPath = root.path
            guard absolute.hasPrefix(rootPath + "/") else {
                throw WPECacheError.extractionFailed("Unpacked WPE project entry escapes its source folder")
            }
            let relative = String(absolute.dropFirst(rootPath.count + 1))
            entries.append((relative, url, values))
        }

        var hasher = SHA256()
        var totalSize: UInt64 = 0
        var latestMTime: TimeInterval = 0
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data(entry.relativePath.utf8))
            if entry.values.isDirectory == true {
                hasher.update(data: Data(" directory\n".utf8))
            } else if entry.values.isRegularFile == true {
                let size = UInt64(max(entry.values.fileSize ?? 0, 0))
                let mtime = entry.values.contentModificationDate?.timeIntervalSince1970 ?? 0
                totalSize += size
                latestMTime = max(latestMTime, mtime)
                hasher.update(data: Data(" file \(size) \(mtime) ".utf8))
                hasher.update(data: Data(try Self.streamingSHA256Hex(of: entry.url).utf8))
                hasher.update(data: Data("\n".utf8))
            }
        }

        let sha = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return Fingerprint(size: totalSize, mtime: latestMTime, sha256: sha)
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
