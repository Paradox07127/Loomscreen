#if !LITE_BUILD
import AppKit
import Foundation
import Observation

/// Owns the one-time security-scoped grant to the Wallpaper Engine install
/// root so the scene renderer can fall through to WPE's bundled framework
/// assets (`<root>/assets/materials`, `<root>/assets/models`, etc.) when a
/// project references shared utility files (`materials/util/composelayer.json`,
/// `models/util/*.json`). Mirrors `AppleAerialsLibrary`; preserves the
/// bookmark across transient resolution failures.
@MainActor
@Observable
final class WPEEngineAssetsLibrary {
    static let shared = WPEEngineAssetsLibrary()

    private(set) var isAuthorized: Bool
    private(set) var lastError: String?
    private(set) var engineRootDisplayName: String?

    init() {
        self.isAuthorized = false
        self.lastError = nil
        self.engineRootDisplayName = nil
        _ = resolveAuthorizedRoot()
    }

    func requestAccess() async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = Self.suggestedDirectoryToGrant()
        panel.prompt = L10n.Panel.grantAccess
        panel.message = String(
            localized: "Choose your Wallpaper Engine install folder. It must contain an assets folder.",
            defaultValue: "Choose your Wallpaper Engine install folder. It must contain an assets folder.",
            comment: "Wallpaper Engine assets folder access panel message."
        )

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return false
        }

        guard let engineRoot = Self.validatedEngineRoot(from: selectedURL) else {
            let message = String(
                localized: "The selected folder doesn't contain Wallpaper Engine assets. Choose the wallpaper_engine install folder or Wallpaper Engine.app.",
                defaultValue: "The selected folder doesn't contain Wallpaper Engine assets. Choose the wallpaper_engine install folder or Wallpaper Engine.app.",
                comment: "Wallpaper Engine assets folder validation error."
            )
            Logger.warning(message, category: .fileAccess)
            lastError = message
            return false
        }

        do {
            let bookmarkData = try Self.createReadOnlyBookmark(for: engineRoot)
            // A manual link supersedes any prior downloaded install — drop the
            // managed marker so `resolveAuthorizedRoot` honors the new folder.
            SettingsManager.shared.wpeEngineAssetsManagedBuildID = nil
            SettingsManager.shared.saveWPEEngineAssetsBookmark(bookmarkData)
            isAuthorized = true
            engineRootDisplayName = engineRoot.lastPathComponent
            lastError = nil
            return true
        } catch {
            let message = "Failed to save Wallpaper Engine assets access: \(error.localizedDescription)"
            Logger.error(message, category: .fileAccess)
            lastError = message
            return false
        }
    }

    func resolveAuthorizedRoot() -> URL? {
        if let managed = Self.managedInstallRoot() {
            isAuthorized = true
            engineRootDisplayName = Self.managedDisplayName
            lastError = nil
            return managed
        }
        return resolveAuthorizedRoot(using: Self.resolveDirectoryBookmark)
    }

    /// Re-derive the published `isAuthorized` / display-name state. Call after a
    /// download or removal mutates the managed install out-of-band.
    func refresh() {
        _ = resolveAuthorizedRoot()
        if !Self.hasManagedInstall && SettingsManager.shared.loadWPEEngineAssetsBookmark() == nil {
            isAuthorized = false
            engineRootDisplayName = nil
        }
    }

    func clearAccess() {
        SettingsManager.shared.wpeEngineAssetsManagedBuildID = nil
        SettingsManager.shared.clearWPEEngineAssetsBookmark()
        isAuthorized = false
        engineRootDisplayName = nil
        lastError = nil
    }
}

// MARK: - Managed (downloaded) install

extension WPEEngineAssetsLibrary {
    /// Durable marker used when disk publication completed but Steam's build ID
    /// was unavailable (or a launch recovered the post-rename/pre-marker cut).
    nonisolated static let unknownManagedBuildMarker = "0"

    static let managedDisplayName = String(
        localized: "Wallpaper Engine (downloaded)",
        defaultValue: "Wallpaper Engine (downloaded)",
        comment: "Engine-assets status when the assets were downloaded in-app via SteamCMD."
    )

    /// `<container>/Library/Application Support/Steam/steamapps/common/wallpaper_engine`
    /// — where a SteamCMD `app_update 431960` lands under the sandbox-redirected
    /// STEAMROOT. In-container: full access, no security-scoped bookmark needed.
    nonisolated static func managedContainerRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine", isDirectory: true)
    }

    /// True when a managed buildid is recorded AND the pruned install still has
    /// its `assets/` subtree. A recorded buildid with no files on disk self-heals
    /// (the stale marker is cleared) so we fall back to any manual link.
    static var hasManagedInstall: Bool { managedInstallRoot() != nil }

    static func managedInstallRoot(fileManager: FileManager = .default) -> URL? {
        guard SettingsManager.shared.wpeEngineAssetsManagedBuildID != nil else { return nil }
        let root = managedContainerRoot()
        guard hasAssetsSubdirectory(root, fileManager: fileManager) else {
            SettingsManager.shared.wpeEngineAssetsManagedBuildID = nil
            return nil
        }
        return root
    }

    /// Engine-assets roots inside the app's own sandbox container need no
    /// security scope — the renderer must not drop them when
    /// `startAccessingSecurityScopedResource()` returns false for them.
    nonisolated static func isContainerInternal(_ url: URL) -> Bool {
        let home = canonicalPath(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        let target = canonicalPath(url)
        return target == home || target.hasPrefix(home + "/")
    }

    /// Symlink-resolved path with any trailing slash stripped. `resolvingSymlinksInPath()`
    /// appends a trailing "/" for existing directories, which would turn the
    /// containment check's `home + "/"` into a non-matching `//`.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

// MARK: - Bookmark Resolution

extension WPEEngineAssetsLibrary {
    struct DirectoryBookmarkResolution {
        let url: URL
        let isStale: Bool
    }

    typealias DirectoryBookmarkResolver = (Data) throws -> DirectoryBookmarkResolution

    func resolveAuthorizedRoot(using resolver: DirectoryBookmarkResolver) -> URL? {
        guard let bookmarkData = SettingsManager.shared.loadWPEEngineAssetsBookmark() else {
            isAuthorized = false
            engineRootDisplayName = nil
            return nil
        }

        do {
            let resolution = try resolver(bookmarkData)
            // A resolved root that no longer contains `assets/` can't serve any
            // framework file, so treat it as unauthorized instead of handing a
            // dead root to the resolver. The bookmark is preserved — the root
            // may just be temporarily unreachable (e.g. an external drive).
            guard let rootURL = Self.validatedEngineRoot(from: resolution.url) else {
                Logger.warning(
                    "Resolved Wallpaper Engine root has no assets folder; treating as unauthorized: \(resolution.url.path(percentEncoded: false))",
                    category: .fileAccess
                )
                isAuthorized = false
                engineRootDisplayName = nil
                return nil
            }

            if resolution.isStale {
                Logger.info(
                    "Wallpaper Engine assets bookmark is stale; refreshing in place",
                    category: .fileAccess
                )
                if let fresh = try? Self.createReadOnlyBookmark(for: rootURL) {
                    SettingsManager.shared.saveWPEEngineAssetsBookmark(fresh)
                }
            }

            isAuthorized = true
            engineRootDisplayName = rootURL.lastPathComponent
            lastError = nil
            return rootURL
        } catch {
            let message = "Failed to resolve Wallpaper Engine assets bookmark: \(error.localizedDescription)"
            Logger.error(message, category: .fileAccess)
            isAuthorized = false
            engineRootDisplayName = nil
            lastError = message
            return nil
        }
    }

    nonisolated static func resolveDirectoryBookmark(_ bookmarkData: Data) throws -> DirectoryBookmarkResolution {
        let (url, isStale) = try SecurityScopedBookmarkResolver.shared.resolveData(bookmarkData)
        return DirectoryBookmarkResolution(url: url, isStale: isStale)
    }

    nonisolated static func createReadOnlyBookmark(for url: URL) throws -> Data {
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        let noKeys: Set<URLResourceKey>? = nil
        let noRelativeURL: URL? = nil
        return try url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: noKeys,
            relativeTo: noRelativeURL
        )
    }
}

// MARK: - Location Helpers

extension WPEEngineAssetsLibrary {
    nonisolated static func suggestedDirectoryToGrant(fileManager: FileManager = .default) -> URL? {
        let steamRoot = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Steam", isDirectory: true)
            .appendingPathComponent("steamapps", isDirectory: true)
            .appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent("wallpaper_engine", isDirectory: true)
        let appRoot = URL(fileURLWithPath: "/Applications/Wallpaper Engine.app", isDirectory: true)
        let appResources = appRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)

        let candidates = [steamRoot, appResources, appRoot]
        if let valid = candidates.compactMap({ validatedEngineRoot(from: $0, fileManager: fileManager) }).first {
            return valid
        }
        if let existing = candidates.first(where: { directoryExists($0, fileManager: fileManager) }) {
            return existing
        }
        return steamRoot.deletingLastPathComponent()
    }

    /// Walks the selected URL — and one common app-bundle relative
    /// (`Contents/Resources/`) — to find the canonical WPE root that
    /// contains an `assets/` subdirectory. Returns nil when no candidate
    /// validates so the caller can surface a precise error.
    nonisolated static func validatedEngineRoot(from selectedURL: URL, fileManager: FileManager = .default) -> URL? {
        let root = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        if hasAssetsSubdirectory(root, fileManager: fileManager) {
            return root
        }

        let appResources = root
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        if hasAssetsSubdirectory(appResources, fileManager: fileManager) {
            return appResources
        }

        // The user may have drilled into the `assets` folder itself; its parent
        // is the canonical root (the resolver appends `assets/` again).
        if root.lastPathComponent == "assets",
           directoryExists(root, fileManager: fileManager),
           hasAssetsSubdirectory(root.deletingLastPathComponent(), fileManager: fileManager) {
            return root.deletingLastPathComponent()
        }
        return nil
    }

    nonisolated static func hasAssetsSubdirectory(_ rootURL: URL, fileManager: FileManager = .default) -> Bool {
        directoryExists(rootURL.appendingPathComponent("assets", isDirectory: true), fileManager: fileManager)
    }

    nonisolated private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
#endif
