#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

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
        // Resolve and start accessing the library root bookmark if available
        var libraryRootURL: URL?
        var didStartLibraryAccess = false
        if let rootData = UserDefaults.standard.data(forKey: "WPELibrary.RootBookmark.v1") {
            if case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(rootData, target: .transient) {
                libraryRootURL = resolved.url
                didStartLibraryAccess = resolved.url.startAccessingSecurityScopedResource()
            }
        }
        defer {
            if didStartLibraryAccess, let libraryRootURL {
                libraryRootURL.stopAccessingSecurityScopedResource()
            }
        }

        // Resolve and start accessing the source folder bookmark if available
        var sourceFolderURL: URL?
        var didStartSourceAccess = false
        if let origin {
            if case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(origin.sourceFolderBookmark, target: .transient) {
                sourceFolderURL = resolved.url
                didStartSourceAccess = resolved.url.startAccessingSecurityScopedResource()
            }
        }
        defer {
            if didStartSourceAccess, let sourceFolderURL {
                sourceFolderURL.stopAccessingSecurityScopedResource()
            }
        }

        let workshopRoot = (libraryRootURL ?? sourceFolderURL?.deletingLastPathComponent())?
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
               let siblingMount = validSourceSiblingMount(
                   workshopID: id,
                   workshopRootURL: workshopRoot,
                   fileManager: fileManager
               ) {
                mounts.append(siblingMount)
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

    private func validSourceSiblingMount(
        workshopID: String,
        workshopRootURL: URL,
        fileManager: FileManager
    ) -> WPEAssetMount? {
        let siblingRoot = workshopRootURL
            .appendingPathComponent(workshopID, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard WPEPathSafety.contains(siblingRoot, in: workshopRootURL),
              Self.isDirectory(siblingRoot, fileManager: fileManager) else {
            return nil
        }

        // Packaged dependency: assets live inside scene.pkg → mount the package
        // for in-place reading (no extraction). Prefer this over the loose folder.
        let pkgURL = siblingRoot.appendingPathComponent("scene.pkg")
        if fileManager.fileExists(atPath: pkgURL.path) {
            return WPEAssetMount(workshopID: workshopID, packageURL: pkgURL)
        }

        // Unpacked dependency: mount the folder if it carries a project.json.
        let manifest = siblingRoot.appendingPathComponent("project.json")
        guard fileManager.fileExists(atPath: manifest.path) else { return nil }
        return WPEAssetMount(workshopID: workshopID, rootURL: siblingRoot)
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
