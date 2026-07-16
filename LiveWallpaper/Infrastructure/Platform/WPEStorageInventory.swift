#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Read-only disk-usage inventory of *downloaded WPE content* — the wallpapers
/// and shared engine assets the app keeps on disk — as opposed to the
/// reclaimable caches in `WallpaperEngineCache` / `WPEVideoTextureDiskCache`.
/// Kept deliberately separate so the Storage UI never conflates "delete this and
/// lose a wallpaper" content with "safe to clear" caches.
///
/// Every size is the on-disk *allocated* footprint (`.totalFileAllocatedSize`,
/// the `du`-equivalent macOS Storage reports), not the logical byte length.
/// Computed off the main actor via `compute()`.
struct WPEStorageInventory: Sendable {
    struct ProjectEntry: Sendable, Identifiable {
        let workshopID: String
        let sizeBytes: UInt64
        let folderURL: URL
        var id: String { workshopID }
    }

    /// Downloaded Workshop projects, largest-first.
    let projects: [ProjectEntry]
    let projectsTotalBytes: UInt64
    /// Footprint of the in-container downloaded Wallpaper Engine assets, 0 when
    /// none were downloaded (a manual external link lives on the user's own disk
    /// and is intentionally not counted as our storage).
    let engineAssetsBytes: UInt64
    let engineAssetsURL: URL?

    static func compute(fileManager: FileManager = .default) -> WPEStorageInventory {
        let projects = scanProjects(fileManager: fileManager)
        let total = projects.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let (assetsBytes, assetsURL) = scanEngineAssets(fileManager: fileManager)
        return WPEStorageInventory(
            projects: projects,
            projectsTotalBytes: total,
            engineAssetsBytes: assetsBytes,
            engineAssetsURL: assetsURL
        )
    }

    private static func scanProjects(fileManager fm: FileManager) -> [ProjectEntry] {
        guard let root = WPEStoragePaths.containerWorkshopContentRoot(fileManager: fm),
              let children = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var entries: [ProjectEntry] = []
        for child in children {
            let id = child.lastPathComponent
            // Reject symlinked id folders: a link could point outside the
            // container and make the size walk follow arbitrary directories.
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard WPEPathSafety.isSafeWorkshopID(id),
                  values?.isDirectory == true,
                  values?.isSymbolicLink != true else { continue }
            let bytes = WPEStoragePaths.allocatedBytes(at: child, fileManager: fm)
            guard bytes > 0 else { continue }
            entries.append(ProjectEntry(workshopID: id, sizeBytes: bytes, folderURL: child))
        }
        return entries.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func scanEngineAssets(fileManager fm: FileManager) -> (UInt64, URL?) {
        let root = WPEEngineAssetsLibrary.managedContainerRoot()
        guard fm.fileExists(atPath: root.path(percentEncoded: false)) else { return (0, nil) }
        let bytes = WPEStoragePaths.allocatedBytes(at: root, fileManager: fm)
        return bytes > 0 ? (bytes, root) : (0, nil)
    }
}
#endif
