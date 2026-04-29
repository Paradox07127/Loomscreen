import Foundation

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
        let data: Data
        do {
            data = try Data(contentsOf: sourcePkgURL, options: .mappedIfSafe)
        } catch {
            Logger.error("WPE pkg unreadable: \(error.localizedDescription)", category: .screenManager)
            throw WPECacheError.pkgUnreadable(error.localizedDescription)
        }

        do {
            let package = try WallpaperEnginePackage.parseIndex(of: data)
            try package.extractAll(from: data, to: cacheURL)
            try writeManifest(
                Manifest(fingerprint: fingerprint, extractedAt: Date().timeIntervalSince1970),
                in: cacheURL
            )
            Logger.info("WPE cache extracted workshop \(workshopID)", category: .screenManager)
            return cacheURL
        } catch {
            Logger.error("WPE extraction failed: \(error.localizedDescription)", category: .screenManager)
            throw WPECacheError.extractionFailed(String(describing: error))
        }
    }

    func purge(workshopID: String) throws {
        let cacheURL = try cacheDirectory(for: workshopID)
        guard fileManager.fileExists(atPath: cacheURL.path) else { return }
        try fileManager.removeItem(at: cacheURL)
        Logger.info("WPE cache purged workshop \(workshopID)", category: .screenManager)
    }

    private func cacheDirectory(for workshopID: String) throws -> URL {
        guard Self.isSafeWorkshopID(workshopID) else {
            throw WPECacheError.invalidWorkshopID(workshopID)
        }
        let root = rootURL.standardizedFileURL
        let candidate = root
            .appendingPathComponent(workshopID, isDirectory: true)
            .standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw WPECacheError.invalidWorkshopID(workshopID)
        }
        return candidate
    }

    private static func isSafeWorkshopID(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("..")
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

    private func fingerprint(for sourcePkgURL: URL) throws -> Fingerprint {
        do {
            let values = try sourcePkgURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values.fileSize,
                  size >= 0,
                  let mtime = values.contentModificationDate?.timeIntervalSince1970 else {
                throw WPECacheError.pkgUnreadable("Missing file metadata")
            }
            return Fingerprint(size: UInt64(size), mtime: mtime)
        } catch let error as WPECacheError {
            throw error
        } catch {
            throw WPECacheError.pkgUnreadable(error.localizedDescription)
        }
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
}

enum WPECacheError: Error, Equatable, Sendable {
    case invalidWorkshopID(String)
    case pkgUnreadable(String)
    case extractionFailed(String)
}
