#if !LITE_BUILD
import Foundation

/// Resolves declared Wallpaper Engine workshop dependency IDs into concrete
/// roots the runtime is allowed to mount. The lookup order mirrors the import
/// dependency gate: prefer our extracted cache, then fall back to sibling
/// Steam Workshop folders next to the imported source project.
struct WPEDependencyMountResolver {
    func mounts(
        dependencyWorkshopIDs: [String],
        origin: WPEOrigin?,
        applicationSupportRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> [WPEAssetMount] {
        let declared = dependencyWorkshopIDs.filter(WPEPathSafety.isSafeWorkshopID)
        guard !declared.isEmpty else { return [] }

        let appSupportRoot = (applicationSupportRootURL ?? WPEPathSafety.defaultApplicationSupportRoot(fileManager: fileManager))?
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let sourceFolderURL = origin.flatMap { WPEPathSafety.resolveSecurityScopedBookmark($0.sourceFolderBookmark) }
        let workshopRoot = sourceFolderURL?
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var mounts: [WPEAssetMount] = []
        for id in declared {
            if let appSupportRoot,
               let cacheRoot = validCacheRoot(
                   workshopID: id,
                   applicationSupportRootURL: appSupportRoot,
                   fileManager: fileManager
               ) {
                mounts.append(WPEAssetMount(workshopID: id, rootURL: cacheRoot))
                continue
            }

            if let workshopRoot,
               let siblingRoot = validSourceSiblingRoot(
                   workshopID: id,
                   workshopRootURL: workshopRoot,
                   fileManager: fileManager
               ) {
                mounts.append(WPEAssetMount(workshopID: id, rootURL: siblingRoot))
            }
        }
        return mounts
    }

    private func validCacheRoot(
        workshopID: String,
        applicationSupportRootURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let cacheRoot = applicationSupportRootURL
            .appendingPathComponent("wpe-cache", isDirectory: true)
            .appendingPathComponent(workshopID, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard WPEPathSafety.contains(cacheRoot, in: applicationSupportRootURL),
              Self.isDirectory(cacheRoot, fileManager: fileManager),
              Self.cacheHasPayload(cacheRoot, fileManager: fileManager) else {
            return nil
        }
        return cacheRoot
    }

    private func validSourceSiblingRoot(
        workshopID: String,
        workshopRootURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let siblingRoot = workshopRootURL
            .appendingPathComponent(workshopID, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard WPEPathSafety.contains(siblingRoot, in: workshopRootURL),
              Self.isDirectory(siblingRoot, fileManager: fileManager) else {
            return nil
        }

        let manifest = siblingRoot.appendingPathComponent("project.json")
        guard fileManager.fileExists(atPath: manifest.path) else { return nil }
        return siblingRoot
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func cacheHasPayload(_ url: URL, fileManager: FileManager) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return entries.contains { $0 != "manifest.json" }
    }

}
#endif
