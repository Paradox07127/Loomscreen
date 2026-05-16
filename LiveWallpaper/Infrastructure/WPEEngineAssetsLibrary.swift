#if !LITE_BUILD
import AppKit
import Foundation
import Observation

/// Owns the one-time security-scoped grant to the Wallpaper Engine install
/// root so the scene renderer can fall through to WPE's bundled framework
/// assets (`<root>/assets/materials`, `<root>/assets/models`, etc.) when a
/// project references shared utility files (`materials/util/composelayer.json`,
/// `models/util/*.json`).
///
/// Mirrors `AppleAerialsLibrary` — single observable owner of the bookmark,
/// caller-driven security-scope start/stop, preserves the bookmark across
/// transient resolution failures.
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
        // Resolve once at boot so observers see the right `isAuthorized`
        // without having to wait for the first runtime read.
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

    /// Resolves the saved bookmark to a usable URL. Callers (runtime scene
    /// renderers) hold the URL for the lifetime of one playback session and
    /// own the `startAccessingSecurityScopedResource()` / `stop...` balance.
    ///
    /// Returns `nil` when no bookmark has been saved OR resolution failed.
    /// Transient resolution failures DO NOT clear the bookmark — see the
    /// `5b0e006` commit ("Preserve Workshop + Aerials bookmarks across
    /// transient scan failures") for the same defensive pattern.
    func resolveAuthorizedRoot() -> URL? {
        resolveAuthorizedRoot(using: Self.resolveDirectoryBookmark)
    }

    func clearAccess() {
        SettingsManager.shared.clearWPEEngineAssetsBookmark()
        isAuthorized = false
        engineRootDisplayName = nil
        lastError = nil
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
            // If the user originally picked the .app bundle, the resolved
            // URL still points at it; re-validate so callers receive the
            // canonical root that contains `assets/`.
            let rootURL = Self.validatedEngineRoot(from: resolution.url) ?? resolution.url

            if resolution.isStale {
                // Apple recommends re-creating the bookmark from the
                // resolved URL when `isStale=true`. The URL is still good
                // for this run; the stored Data needs a fresh copy so
                // future relaunches don't trip the flag again.
                Logger.info(
                    "Wallpaper Engine assets bookmark is stale; refreshing in place",
                    category: .fileAccess
                )
                if let fresh = try? Self.createReadOnlyBookmark(for: rootURL) {
                    SettingsManager.shared.saveWPEEngineAssetsBookmark(fresh)
                }
            }

            if !Self.hasAssetsSubdirectory(rootURL) {
                Logger.warning(
                    "Resolved Wallpaper Engine root has no assets folder: \(rootURL.path(percentEncoded: false))",
                    category: .fileAccess
                )
            }

            isAuthorized = true
            engineRootDisplayName = rootURL.lastPathComponent
            lastError = nil
            return rootURL
        } catch {
            // Resolution failed — could be transient (sandbox not warmed,
            // home directory moved by Migration Assistant). Surface the
            // error but KEEP the saved bookmark so the next launch /
            // explicit retry can resolve it.
            let message = "Failed to resolve Wallpaper Engine assets bookmark: \(error.localizedDescription)"
            Logger.error(message, category: .fileAccess)
            isAuthorized = false
            engineRootDisplayName = nil
            lastError = message
            return nil
        }
    }

    nonisolated static func resolveDirectoryBookmark(_ bookmarkData: Data) throws -> DirectoryBookmarkResolution {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
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
        // Prefer a validated WPE root (we can confirm `assets/` exists).
        if let valid = candidates.compactMap({ validatedEngineRoot(from: $0, fileManager: fileManager) }).first {
            return valid
        }
        // Otherwise point at whichever candidate exists as a directory.
        if let existing = candidates.first(where: { directoryExists($0, fileManager: fileManager) }) {
            return existing
        }
        // Last resort: the parent of the Steam path so the user can
        // navigate. Returns nil only if even the home directory is gone.
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
