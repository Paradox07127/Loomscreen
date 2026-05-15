import Foundation
import CoreGraphics
import AppKit
import AVFoundation
import ServiceManagement

@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    private var cachedGlobalSettings: GlobalSettings?
    private var cachedConfigurations: [ScreenConfiguration]?

    /// Three big JSON blobs that used to live in `UserDefaults`. Moved to
    /// `~/Library/Application Support/<bundle-id>/Configuration/` so writes
    /// are observable, atomic, and independent of `cfprefsd`. Small
    /// primitives (language, bookmarks for single folders, trusted hosts)
    /// remain in `UserDefaults` because they're boot-critical and tiny.
    private let screenConfigStore: AtomicFileStore<[ScreenConfiguration]>
    private let globalSettingsStore: AtomicFileStore<GlobalSettings>
    private let wallpaperBookmarksStore: AtomicFileStore<[WallpaperBookmark]>

    private enum Keys {
        static let screenConfigurations = "screenConfigurations"
        static let globalSettings = "globalSettings"
        static let lastUsedDirectory = "lastUsedDirectory"
        static let aerialsDirectoryBookmark = "AerialsLibrary.DirectoryBookmark"
        static let bookmarks = "WallpaperBookmarks.v1"
        static let trustedHosts = "TrustedHTMLHosts.v1"
        static let workshopLibraryRootBookmark = "WPELibrary.RootBookmark.v1"
        static let wpeEngineAssetsRootBookmark = "WPEEngineAssets.RootBookmark.v1"
        static let appLanguage = AppLanguagePreference.storageKey
        /// Bumped each time we successfully migrate a blob out of UserDefaults
        /// into the file store. Lets us run the migration at most once even
        /// though we keep the legacy keys for one version (rollback safety).
        static let configMigrationVersion = "Settings.MigrationVersion"
    }

    /// Current migration revision. Bump when introducing a new file-backed
    /// store or schema change so the migration path re-runs on next launch.
    private static let currentMigrationVersion = 1

    init(directory: ConfigurationDirectory = ConfigurationDirectory()) {
        self.screenConfigStore = AtomicFileStore(
            fileURL: directory.url(for: .screenConfigurations)
        )
        self.globalSettingsStore = AtomicFileStore(
            fileURL: directory.url(for: .globalSettings)
        )
        self.wallpaperBookmarksStore = AtomicFileStore(
            fileURL: directory.url(for: .wallpaperBookmarks)
        )

        migrateLegacyUserDefaultsIfNeeded()
    }

    // MARK: - Screen Configurations

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        var configs = loadConfigurations()
        if let index = configs.firstIndex(where: { $0.screenID == configuration.screenID }) {
            configs[index] = configuration
        } else {
            configs.append(configuration)
        }
        // persistConfigurations owns the cache update — it only writes the
        // cache after the disk write succeeds.
        persistConfigurations(configs)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        persistConfigurations(configurations)
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        if let cached = cachedConfigurations { return cached }
        let configs = screenConfigStore.read() ?? []
        cachedConfigurations = configs
        return configs
    }

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        loadConfigurations().first { $0.screenID == screenID }
    }

    /// Persists the array and only updates the in-memory cache if the disk
    /// write succeeds. This way a transient disk-full / permission error
    /// doesn't silently desync cache from durable state.
    private func persistConfigurations(_ configs: [ScreenConfiguration]) {
        do {
            try screenConfigStore.write(configs)
            cachedConfigurations = configs
        } catch {
            Logger.error("Failed to persist screen configurations: \(error.localizedDescription)", category: .settings)
            // Drop the cache so the next read goes back to disk (which
            // still has the previous good version).
            cachedConfigurations = nil
        }
    }
    
    // MARK: - Global Settings

    func saveGlobalSettings(_ settings: GlobalSettings) {
        let previousStartOnLogin = cachedGlobalSettings?.startOnLogin ?? loadGlobalSettings().startOnLogin
        do {
            // Write to disk first; only commit the cache if it sticks.
            try globalSettingsStore.write(settings)
            cachedGlobalSettings = settings
            if previousStartOnLogin != settings.startOnLogin {
                applyStartOnLoginSetting(settings.startOnLogin)
            }
            Logger.settingsChanged(setting: "globalSettings", value: "Updated global settings")
        } catch {
            Logger.error("Failed to persist global settings: \(error.localizedDescription)", category: .settings)
            // Force a re-read on next access so we return the last-good
            // persisted version instead of the rejected update.
            cachedGlobalSettings = nil
        }
    }

    func loadGlobalSettings() -> GlobalSettings {
        if let cached = cachedGlobalSettings { return cached }
        let settings = globalSettingsStore.read() ?? GlobalSettings()
        cachedGlobalSettings = settings
        return settings
    }

    // MARK: - Wallpaper Engine History (LRU, capped at 20)

    func recordWPEImport(_ entry: WPEHistoryEntry) {
        var settings = loadGlobalSettings()
        var recent = settings.recentWPEImports.filter {
            $0.origin.workshopID != entry.origin.workshopID
        }
        recent.insert(entry, at: 0)
        if recent.count > 20 {
            recent = Array(recent.prefix(20))
        }
        settings.recentWPEImports = recent
        saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    func removeWPEImport(workshopID: String) {
        var settings = loadGlobalSettings()
        let previous = settings.recentWPEImports
        settings.recentWPEImports.removeAll { $0.origin.workshopID == workshopID }
        guard settings.recentWPEImports != previous else { return }
        saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    // MARK: - Workshop Library Root Bookmark (Phase 1.5 gallery)

    /// Persists the security-scoped bookmark to the user-chosen Workshop
    /// library root (e.g. `~/Documents/Live Wallpapers/431960/`). The bookmark
    /// is created via `NSOpenPanel` once and reused on subsequent scans.
    func saveWorkshopLibraryRootBookmark(_ bookmark: Data) {
        UserDefaults.standard.set(bookmark, forKey: Keys.workshopLibraryRootBookmark)
        NotificationCenter.default.post(name: .workshopLibraryRootBookmarkDidChange, object: nil)
    }

    func loadWorkshopLibraryRootBookmark() -> Data? {
        UserDefaults.standard.data(forKey: Keys.workshopLibraryRootBookmark)
    }

    func clearWorkshopLibraryRootBookmark() {
        UserDefaults.standard.removeObject(forKey: Keys.workshopLibraryRootBookmark)
        NotificationCenter.default.post(name: .workshopLibraryRootBookmarkDidChange, object: nil)
    }

    // MARK: - Wallpaper Engine Assets Root Bookmark

    /// Persists the security-scoped bookmark to the Wallpaper Engine install
    /// root. Scene renderers mount `<root>/assets` as a read-only fallback so
    /// projects that reference shared engine framework files (e.g.
    /// `materials/util/composelayer.json`) can resolve them.
    func saveWPEEngineAssetsBookmark(_ bookmark: Data) {
        UserDefaults.standard.set(bookmark, forKey: Keys.wpeEngineAssetsRootBookmark)
        NotificationCenter.default.post(name: .wpeEngineAssetsBookmarkDidChange, object: nil)
    }

    func loadWPEEngineAssetsBookmark() -> Data? {
        UserDefaults.standard.data(forKey: Keys.wpeEngineAssetsRootBookmark)
    }

    func clearWPEEngineAssetsBookmark() {
        UserDefaults.standard.removeObject(forKey: Keys.wpeEngineAssetsRootBookmark)
        NotificationCenter.default.post(name: .wpeEngineAssetsBookmarkDidChange, object: nil)
    }

    private func applyStartOnLoginSetting(_ startOnLogin: Bool) {
        do {
            let service = SMAppService.mainApp

            if startOnLogin {
                if service.status == .notRegistered {
                    try service.register()
                    Logger.info("Successfully added to login items", category: .settings)
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                    Logger.info("Successfully removed from login items", category: .settings)
                }
            }
        } catch {
            Logger.error("Failed to \(startOnLogin ? "add to" : "remove from") login items: \(error.localizedDescription)", category: .settings)
        }
    }

    // MARK: - Clean Settings

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        var configs = loadConfigurations()
        configs.removeAll { $0.screenID == screenID }
        cachedConfigurations = configs
        persistConfigurations(configs)
    }

    func cleanAllSettings(applyLoginSetting: Bool = true) {
        cachedGlobalSettings = nil
        cachedConfigurations = nil

        // File-backed stores (large blobs).
        screenConfigStore.delete()
        globalSettingsStore.delete()
        wallpaperBookmarksStore.delete()

        // Legacy UserDefaults keys (kept for rollback during the migration
        // window). Clearing them here makes Reset truly idempotent.
        UserDefaults.standard.removeObject(forKey: Keys.screenConfigurations)
        UserDefaults.standard.removeObject(forKey: Keys.globalSettings)
        UserDefaults.standard.removeObject(forKey: Keys.aerialsDirectoryBookmark)
        UserDefaults.standard.removeObject(forKey: Keys.bookmarks)
        UserDefaults.standard.removeObject(forKey: Keys.trustedHosts)
        UserDefaults.standard.removeObject(forKey: Keys.workshopLibraryRootBookmark)
        UserDefaults.standard.removeObject(forKey: Keys.wpeEngineAssetsRootBookmark)
        UserDefaults.standard.removeObject(forKey: Keys.appLanguage)
        // `configMigrationVersion` is intentionally preserved — it tracks
        // "which migration steps have already been applied to this install",
        // not "is there data". Resetting it would re-run the seed pass on
        // the next launch; with the legacy keys already cleared above
        // that's a no-op today, but keeping the counter prevents any
        // future migration step from re-firing against partially-cleared
        // state.

        BookmarkStore.shared.resetAfterSettingsCleared()
        TrustedHostStore.shared.resetAfterSettingsCleared()
        if applyLoginSetting {
            applyStartOnLoginSetting(false)
        }
    }

    // MARK: - Legacy Migration

    /// Seeds the new file-backed stores from any pre-existing `UserDefaults`
    /// blobs. Idempotent — gated on `Keys.configMigrationVersion` but only
    /// when every required seed succeeded. A transient disk-full / TCC /
    /// read-only home will leave the version counter at zero so the next
    /// launch retries; otherwise we'd permanently strand the user's data.
    ///
    /// The legacy UserDefaults entries are intentionally NOT removed here
    /// so users can roll back to the previous app version once if needed.
    /// The next release will drop them.
    private func migrateLegacyUserDefaultsIfNeeded() {
        let storedVersion = UserDefaults.standard.integer(forKey: Keys.configMigrationVersion)
        guard storedVersion < Self.currentMigrationVersion else { return }

        var allSucceeded = true
        allSucceeded = seedStoreFromUserDefaults(
            store: screenConfigStore,
            legacyKey: Keys.screenConfigurations,
            label: "screenConfigurations"
        ) && allSucceeded
        allSucceeded = seedStoreFromUserDefaults(
            store: globalSettingsStore,
            legacyKey: Keys.globalSettings,
            label: "globalSettings"
        ) && allSucceeded
        allSucceeded = seedStoreFromUserDefaults(
            store: wallpaperBookmarksStore,
            legacyKey: Keys.bookmarks,
            label: "wallpaperBookmarks"
        ) && allSucceeded

        guard allSucceeded else {
            Logger.error(
                "SettingsManager migration v\(Self.currentMigrationVersion) DID NOT complete cleanly; will retry on next launch",
                category: .settings
            )
            return
        }

        UserDefaults.standard.set(Self.currentMigrationVersion, forKey: Keys.configMigrationVersion)
        Logger.info(
            "SettingsManager migration v\(Self.currentMigrationVersion) complete",
            category: .settings
        )
    }

    /// Returns `true` if the seed step succeeded — either the legacy blob
    /// was absent (nothing to do) or it was successfully written to the
    /// file store. Returns `false` only on an actual write/encode failure
    /// so the caller can defer bumping the migration version.
    private func seedStoreFromUserDefaults<V: Codable>(
        store: AtomicFileStore<V>,
        legacyKey: String,
        label: String
    ) -> Bool {
        // Never overwrite an existing file payload — the file always wins.
        guard !store.hasPersistedValue else { return true }
        guard let data = UserDefaults.standard.data(forKey: legacyKey) else { return true }
        do {
            try store.writeRaw(data)
            Logger.info(
                "Migrated \(label) from UserDefaults → file (\(data.count) bytes)",
                category: .settings
            )
            return true
        } catch {
            Logger.error(
                "Failed to migrate \(label): \(error.localizedDescription)",
                category: .settings
            )
            return false
        }
    }
    
    // MARK: - Validation

    func validateConfiguration(for screenID: CGDirectDisplayID) -> Bool {
        guard let configuration = loadConfigurations().first(where: { $0.screenID == screenID }) else { return false }

        guard let definition = WallpaperSessionDefinition(configuration: configuration) else {
            Logger.error("Malformed wallpaper configuration for screen \(screenID)", category: .settings)
            return false
        }

        switch definition {
        case .video(let bookmarkData):
            return validateVideoBookmark(bookmarkData, for: screenID, configuration: configuration)
        case .html(let source, _):
            return validateHTMLSource(source, for: screenID)
        case .metalShader:
            return true
        case .scene(let descriptor):
            // The cache resolver re-validates `cacheRelativePath` on resume,
            // so here we only confirm the descriptor still has the parts
            // needed to even attempt a cache lookup.
            return !descriptor.workshopID.isEmpty
                && !descriptor.cacheRelativePath.isEmpty
                && !descriptor.entryFile.isEmpty
        }
    }

    private func validateVideoBookmark(
        _ bookmarkData: Data,
        for screenID: CGDirectDisplayID,
        configuration: ScreenConfiguration
    ) -> Bool {
        do {
            let resolution = try ResourceUtilities.resolveBookmark(bookmarkData)
            let url = resolution.url

            let canAccess = url.startAccessingSecurityScopedResource()
            if resolution.isStale && resolution.isSecurityScoped && canAccess {
                Logger.warning("Stale bookmark detected for screen \(screenID), refreshing", category: .fileAccess)
                let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                let noKeys: Set<URLResourceKey>? = nil
                let noRelative: URL? = nil
                if let updatedBookmark = try? url.bookmarkData(
                    options: bookmarkOptions,
                    includingResourceValuesForKeys: noKeys,
                    relativeTo: noRelative
                ) {
                    let updatedConfig = configuration.withUpdatedActiveBookmark(updatedBookmark)
                    saveConfiguration(updatedConfig)
                    Logger.info("Refreshed stale bookmark for screen \(screenID)", category: .fileAccess)
                }
            }
            if canAccess {
                url.stopAccessingSecurityScopedResource()
            } else if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                return true
            } else {
                Logger.error("Cannot access file for screen \(screenID)", category: .fileAccess)
            }
            return canAccess
        } catch {
            Logger.error("Failed to resolve bookmark for screen \(screenID): \(error.localizedDescription)", category: .fileAccess)
            return false
        }
    }

    private func validateHTMLSource(_ source: HTMLSource, for screenID: CGDirectDisplayID) -> Bool {
        switch source {
        case .inline:
            return true
        case .url(let url):
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                Logger.error("Invalid remote HTML URL for screen \(screenID): \(url.absoluteString)", category: .fileAccess)
                return false
            }
            return true
        case .file(let bookmarkData):
            return validateLocalHTMLBookmark(bookmarkData, indexFileName: nil, for: screenID)
        case .folder(let bookmarkData, let indexFileName):
            return validateLocalHTMLBookmark(bookmarkData, indexFileName: indexFileName, for: screenID)
        }
    }

    private func validateLocalHTMLBookmark(
        _ bookmarkData: Data,
        indexFileName: String?,
        for screenID: CGDirectDisplayID
    ) -> Bool {
        do {
            let resolution = try ResourceUtilities.resolveBookmark(bookmarkData)
            let url = resolution.url

            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard canAccess || FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                Logger.error("Cannot access local HTML resource for screen \(screenID)", category: .fileAccess)
                return false
            }

            if let indexFileName {
                let escapedIndex = indexFileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? indexFileName
                guard let requestURL = URL(string: "\(FolderURLSchemeHandler.scheme)://\(FolderURLSchemeHandler.host)/\(escapedIndex)") else {
                    Logger.error("Invalid HTML folder index name for screen \(screenID): \(indexFileName)", category: .fileAccess)
                    return false
                }
                let indexURL = try FolderURLSchemeHandler.resolvedFileURL(
                    for: requestURL,
                    inside: url
                )
                return FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false))
            }

            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        } catch {
            Logger.error("Failed to resolve local HTML bookmark for screen \(screenID): \(error.localizedDescription)", category: .fileAccess)
            return false
        }
    }

    // MARK: - User Preferences

    func saveLastUsedDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path(percentEncoded: false), forKey: Keys.lastUsedDirectory)
    }

    func getLastUsedDirectory() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: Keys.lastUsedDirectory) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        if url.exists {
            return url
        }
        Logger.warning("Last used directory no longer exists: \(path)", category: .fileAccess)
        return nil
    }

    // MARK: - Apple Aerials Library

    func saveAerialsDirectoryBookmark(_ bookmarkData: Data) {
        UserDefaults.standard.set(bookmarkData, forKey: Keys.aerialsDirectoryBookmark)
    }

    func loadAerialsDirectoryBookmark() -> Data? {
        UserDefaults.standard.data(forKey: Keys.aerialsDirectoryBookmark)
    }

    func clearAerialsDirectoryBookmark() {
        UserDefaults.standard.removeObject(forKey: Keys.aerialsDirectoryBookmark)
    }

    // MARK: - Wallpaper Bookmarks

    func loadWallpaperBookmarks() -> [WallpaperBookmark] {
        wallpaperBookmarksStore.read() ?? []
    }

    func saveWallpaperBookmarks(_ bookmarks: [WallpaperBookmark]) {
        do {
            try wallpaperBookmarksStore.write(bookmarks)
        } catch {
            Logger.error("Failed to persist wallpaper bookmarks: \(error.localizedDescription)", category: .settings)
        }
    }

    // MARK: - Trusted HTML Hosts

    func loadTrustedHosts() -> [String] {
        UserDefaults.standard.stringArray(forKey: Keys.trustedHosts) ?? []
    }

    func saveTrustedHosts(_ hosts: [String]) {
        UserDefaults.standard.set(hosts, forKey: Keys.trustedHosts)
    }
}

// MARK: - URL Extension
extension URL {
    // Check if URL exists
    var exists: Bool {
        FileManager.default.fileExists(atPath: path(percentEncoded: false))
    }
}
