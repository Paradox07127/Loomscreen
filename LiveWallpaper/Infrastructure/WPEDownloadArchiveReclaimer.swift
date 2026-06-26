#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation

/// Reclaims disk by trashing the redundant source `scene.pkg` archives SteamCMD
/// left in the container Steam download tree once their payload was unpacked
/// into `wpe-cache`. The runtime reads the cache copy, so the source archive is
/// dead weight after import.
///
/// Safe because SteamCMD tracks completion via its `appworkshop_431960.acf`
/// manifest, not a content scan: removing the `.pkg` while leaving the item
/// folder + manifest intact does not trigger a re-download. Only `.pkg`s of ids
/// confirmed present in the cache are touched (never the sole copy), and the
/// archive is moved to the Trash (recoverable), never unlinked.
struct WPEDownloadArchiveReclaimer {
    /// Root of downloaded Workshop items (`…/content/431960/`).
    let contentRoot: URL?
    private let fileManager: FileManager

    init(
        contentRoot: URL? = WPEDownloadArchiveReclaimer.containerSteamContentRoot(),
        fileManager: FileManager = .default
    ) {
        self.contentRoot = contentRoot
        self.fileManager = fileManager
    }

    /// Container-local SteamCMD Workshop content root — where a sandboxed app's
    /// steamcmd actually writes (STEAMROOT redirected into the container). Chain-
    /// anchored to Application Support so a symlinked `Steam` can't re-base it.
    static func containerSteamContentRoot(fileManager: FileManager = .default) -> URL? {
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        let safeAppSupport = appSupport.standardizedFileURL.resolvingSymlinksInPath()
        let steam = safeAppSupport
            .appendingPathComponent("Steam", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard WPEPathSafety.contains(steam, in: safeAppSupport) else { return nil }
        let contentRoot = steam
            .appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard WPEPathSafety.contains(contentRoot, in: steam) else { return nil }
        return contentRoot
    }

    func reclaimableBytes(cachedIDs: Set<String>) -> Int64 {
        cachedIDs.reduce(into: Int64(0)) { sum, id in
            if let pkg = sourceArchiveURL(for: id) { sum += fileSize(pkg) }
        }
    }

    /// Trashes the source `scene.pkg` for every already-cached id that still has
    /// one. Returns the count trashed + bytes freed.
    @discardableResult
    func reclaim(cachedIDs: Set<String>) -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for id in cachedIDs {
            guard let pkg = sourceArchiveURL(for: id) else { continue }
            let size = fileSize(pkg)
            do {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: pkg, resultingItemURL: &resultingURL)
                count += 1
                bytes += size
            } catch {
                continue
            }
        }
        return (count, bytes)
    }

    /// Resolved, containment-checked `scene.pkg` for a cached id when one exists
    /// as a regular file inside the (symlink-resolved) content root.
    private func sourceArchiveURL(for workshopID: String) -> URL? {
        guard let contentRoot, WPEPathSafety.isSafeWorkshopID(workshopID) else { return nil }
        let root = contentRoot.standardizedFileURL.resolvingSymlinksInPath()

        // Reject a symlinked id folder outright (it could re-base onto a sibling
        // item's archive), then anchor the resolved folder inside the content root.
        let itemURL = root.appendingPathComponent(workshopID, isDirectory: true).standardizedFileURL
        guard (try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        let item = itemURL.resolvingSymlinksInPath()
        guard WPEPathSafety.contains(item, in: root) else { return nil }

        // Same for the archive: no symlink, and the resolved file must stay
        // inside the resolved id folder — not merely the content root.
        let pkgURL = item.appendingPathComponent("scene.pkg", isDirectory: false).standardizedFileURL
        guard (try? pkgURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        let pkg = pkgURL.resolvingSymlinksInPath()
        guard WPEPathSafety.contains(pkg, in: item) else { return nil }
        guard (try? pkg.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return pkg
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
#endif
