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

    /// Serial off-MainActor writer for `screenConfigStore`. Cache mutations
    /// remain synchronous on MainActor; disk encode/fsync/rename are queued
    /// to this actor so toggle/slider handlers return immediately instead of
    /// blocking the UI for tens of milliseconds per write.
    private let configurationPersistenceActor: WallpaperPersistenceActor

    /// Monotonic counter assigned to every screen-configuration write or
    /// delete so the persistence actor can drop submissions that were
    /// superseded by a newer MainActor mutation while the prior task was
    /// still in flight.
    private var configurationWriteGeneration: UInt64 = 0

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
        /// though we keep the legacy keys for one version as a compatibility
        /// buffer.
        static let configMigrationVersion = "Settings.MigrationVersion"
    }

    /// Current migration revision. Bump when introducing a new file-backed
    /// store or schema change so the migration path re-runs on next launch.
    private static let currentMigrationVersion = 1

    init(directory: ConfigurationDirectory = ConfigurationDirectory()) {
        let screenConfigStore = AtomicFileStore<[ScreenConfiguration]>(
            fileURL: directory.url(for: .screenConfigurations)
        )
        self.screenConfigStore = screenConfigStore
        self.configurationPersistenceActor = WallpaperPersistenceActor(store: screenConfigStore)
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

    /// Updates the in-memory cache synchronously so MainActor readers observe
    /// the new value before this function returns; disk write is queued async.
    private func persistConfigurations(_ configs: [ScreenConfiguration]) {
        configurationWriteGeneration &+= 1
        let generation = configurationWriteGeneration
        cachedConfigurations = configs
        Task { [weak self, configurationPersistenceActor] in
            do {
                try await configurationPersistenceActor.write(configs, generation: generation)
            } catch {
                await MainActor.run {
                    guard let self,
                          self.configurationWriteGeneration == generation else { return }
                    Logger.error(
                        "Failed to persist screen configurations: \(error.localizedDescription)",
                        category: .settings
                    )
                    self.cachedConfigurations = nil
                }
            }
        }
    }

    func flushPendingConfigurationWrites() async {
        configurationWriteGeneration &+= 1
        let generation = configurationWriteGeneration
        do {
            try await configurationPersistenceActor.write(loadConfigurations(), generation: generation)
        } catch {
            Logger.error(
                "Final configuration flush failed: \(error.localizedDescription)",
                category: .settings
            )
        }
    }
    
    // MARK: - Global Settings

    func saveGlobalSettings(_ settings: GlobalSettings) {
        let previousStartOnLogin = cachedGlobalSettings?.startOnLogin ?? loadGlobalSettings().startOnLogin
        do {
            try globalSettingsStore.write(settings)
            cachedGlobalSettings = settings
            if previousStartOnLogin != settings.startOnLogin {
                applyStartOnLoginSetting(settings.startOnLogin)
            }
            Logger.settingsChanged(setting: "globalSettings", value: "Updated global settings")
        } catch {
            Logger.error("Failed to persist global settings: \(error.localizedDescription)", category: .settings)
            cachedGlobalSettings = nil
        }
    }

    func loadGlobalSettings() -> GlobalSettings {
        if let cached = cachedGlobalSettings { return cached }
        let settings = globalSettingsStore.read() ?? GlobalSettings()
        cachedGlobalSettings = settings
        return settings
    }

    // MARK: - Wallpaper Engine History (managed library, LRU-bounded)

    /// Upper bound on the managed library. Each entry embeds a security-scoped
    /// bookmark (~1–3 KB of JSON) and lives in the single `global-settings.json`
    /// blob, so this caps that blob's growth rather than guarding a real
    /// database. 200 covers a large hand-curated library; raise further (or move
    /// to a dedicated store) if the library is meant to be effectively unbounded.
    static let maxRecentWPEImports = 200

    func recordWPEImport(_ entry: WPEHistoryEntry) {
        var settings = loadGlobalSettings()
        // History activation re-records an entry with `sizeBytes == nil`; carry
        // the previously measured size forward so it isn't thrown away (and
        // re-walked) on every apply.
        var entry = entry
        if entry.sizeBytes == nil {
            entry.sizeBytes = settings.recentWPEImports.first {
                $0.origin.workshopID == entry.origin.workshopID
            }?.sizeBytes
        }
        var recent = settings.recentWPEImports.filter {
            $0.origin.workshopID != entry.origin.workshopID
        }
        recent.insert(entry, at: 0)
        if recent.count > Self.maxRecentWPEImports {
            recent = Array(recent.prefix(Self.maxRecentWPEImports))
        }
        settings.recentWPEImports = recent
        // A deliberate (re-)import overrides a prior delete: drop any tombstone so
        // the item is no longer suppressed by the auto-import scan.
        settings.deletedWorkshopIDs.removeAll { $0 == entry.origin.workshopID }
        saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    /// Backfills a single import's measured folder size. Patches only that one
    /// field on the still-present entry (no whole-blob clobber from a stale
    /// captured copy), and only when it hasn't been measured yet.
    func updateWPEImportSize(workshopID: String, sizeBytes: Int64) {
        var settings = loadGlobalSettings()
        guard let index = settings.recentWPEImports.firstIndex(where: {
            $0.origin.workshopID == workshopID
        }), settings.recentWPEImports[index].sizeBytes == nil else { return }
        settings.recentWPEImports[index].sizeBytes = sizeBytes
        saveGlobalSettings(settings)
    }

    /// Upper bound on the delete-tombstone list. Each tombstone is just a
    /// workshop-ID string, but it lives in the single `global-settings.json`
    /// blob, so cap its growth; the oldest fall off first.
    static let maxDeletedWorkshopTombstones = 500

    /// SKU-neutral equivalent of `WPEPathSafety.isSafeWorkshopID` (which is
    /// Pro-only): rejects empty, `.`/`..`, and any separator so a persisted
    /// tombstone can never carry an escape-capable component.
    private static func isSafeWorkshopIDComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("..")
    }

    /// Records that the user deleted `workshopID`, so the auto-import scan won't
    /// resurrect it from a still-present SteamCMD download or library-folder
    /// copy. A later deliberate re-import clears it (see `recordWPEImport`).
    func recordWPEDeleteTombstone(workshopID: String) {
        // Tombstones are persisted scan policy, so keep the list clean: reject
        // any id that isn't a safe path component (mirrors ProWPE's
        // `WPEPathSafety.isSafeWorkshopID`, inlined here because that type is
        // Pro-only while this method is compiled into both SKUs).
        guard Self.isSafeWorkshopIDComponent(workshopID) else { return }
        var settings = loadGlobalSettings()
        guard !settings.deletedWorkshopIDs.contains(workshopID) else { return }
        settings.deletedWorkshopIDs.insert(workshopID, at: 0)
        if settings.deletedWorkshopIDs.count > Self.maxDeletedWorkshopTombstones {
            settings.deletedWorkshopIDs = Array(settings.deletedWorkshopIDs.prefix(Self.maxDeletedWorkshopTombstones))
        }
        saveGlobalSettings(settings)
    }

    func removeWPEImport(workshopID: String) {
        var settings = loadGlobalSettings()
        let previous = settings.recentWPEImports
        settings.recentWPEImports.removeAll { $0.origin.workshopID == workshopID }
        guard settings.recentWPEImports != previous else { return }
        saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    // MARK: - Workshop Library Root Bookmark

    /// Workshop library root is the user-chosen folder, e.g. `~/Documents/Live Wallpapers/431960/`.
    func saveWorkshopLibraryRootBookmark(_ bookmark: Data) {
        UserDefaults.standard.set(bookmark, forKey: Keys.workshopLibraryRootBookmark)
        NotificationCenter.default.post(name: .workshopLibraryRootBookmarkDidChange, object: nil)
    }

    func loadWorkshopLibraryRootBookmark() -> Data? {
        UserDefaults.standard.data(forKey: Keys.workshopLibraryRootBookmark)
    }

    // MARK: - Wallpaper Engine Assets Root Bookmark

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
        let service = SMAppService.mainApp
        let statusBefore = service.status
        Logger.debug(
            "applyStartOnLoginSetting target=\(startOnLogin) statusBefore=\(describe(statusBefore)) bundlePath=\(Bundle.main.bundlePath)",
            category: .settings
        )

        do {
            if startOnLogin {
                if statusBefore == .notRegistered || statusBefore == .notFound {
                    try service.register()
                }
            } else {
                if statusBefore == .enabled || statusBefore == .requiresApproval {
                    try service.unregister()
                }
            }
        } catch {
            Logger.error(
                "SMAppService.\(startOnLogin ? "register" : "unregister") threw: \(error.localizedDescription)",
                category: .settings
            )
            postLoginItemFailure(reason: .registrationFailed(error))
            return
        }

        let statusAfter = service.status
        Logger.debug("SMAppService statusAfter=\(describe(statusAfter))", category: .settings)

        switch (startOnLogin, statusAfter) {
        case (true, .enabled), (false, .notRegistered), (false, .notFound):
            break  // happy paths
        case (true, .requiresApproval):
            Logger.warning("Login item registered but requires user approval in System Settings", category: .settings)
            postLoginItemFailure(reason: .requiresApproval)
        case (true, .notRegistered), (true, .notFound):
            Logger.error("Login item register() returned without error but status is \(describe(statusAfter)); app may not be in /Applications/ or signing is rejected", category: .settings)
            postLoginItemFailure(reason: .registrationSilentlyFailed)
        case (false, _):
            Logger.warning("Login item disable target=false but statusAfter=\(describe(statusAfter))", category: .settings)
        default:
            break
        }
    }

    private func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:    return "notRegistered"
        case .enabled:          return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound:         return "notFound"
        @unknown default:       return "unknown(\(status.rawValue))"
        }
    }

    private func postLoginItemFailure(reason: LoginItemFailure) {
        NotificationCenter.default.post(
            name: .loginItemRegistrationDidFail,
            object: nil,
            userInfo: ["reason": reason]
        )
    }

    // MARK: - Clean Settings

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        var configs = loadConfigurations()
        configs.removeAll { $0.screenID == screenID }
        cachedConfigurations = configs
        persistConfigurations(configs)
    }

    func cleanAllSettings(applyLoginSetting: Bool = true) {
        cachedGlobalSettings = GlobalSettings()
        cachedConfigurations = []

        configurationWriteGeneration &+= 1
        let generation = configurationWriteGeneration
        Task { [configurationPersistenceActor] in
            await configurationPersistenceActor.delete(generation: generation)
        }
        globalSettingsStore.delete()
        wallpaperBookmarksStore.delete()

        UserDefaults.standard.removeObject(forKey: Keys.screenConfigurations)
        UserDefaults.standard.removeObject(forKey: Keys.globalSettings)
        UserDefaults.standard.removeObject(forKey: Keys.aerialsDirectoryBookmark)
        UserDefaults.standard.removeObject(forKey: Keys.bookmarks)
        UserDefaults.standard.removeObject(forKey: Keys.trustedHosts)
        UserDefaults.standard.removeObject(forKey: Keys.workshopLibraryRootBookmark)
        UserDefaults.standard.removeObject(forKey: Keys.wpeEngineAssetsRootBookmark)
        UserDefaults.standard.removeObject(forKey: Keys.appLanguage)

        BookmarkStore.shared.resetAfterSettingsCleared()
        TrustedHostStore.shared.resetAfterSettingsCleared()
        if applyLoginSetting {
            applyStartOnLoginSetting(false)
        }
    }

    // MARK: - Legacy Migration

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

    /// Returns `true` if the seed step succeeded — either the legacy blob was absent (nothing to do) or it was successfully written to the file store.
    private func seedStoreFromUserDefaults<V: Codable>(
        store: AtomicFileStore<V>,
        legacyKey: String,
        label: String
    ) -> Bool {
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
        case .video(let bookmarkData, _):
            return validateVideoBookmark(bookmarkData, for: screenID, configuration: configuration)
        case .html(let source, _):
            return validateHTMLSource(source, for: screenID)
        case .metalShader:
            return true
        case .scene(let descriptor):
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
        switch SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient) {
        case .success(let resolved):
            let url = resolved.url
            if resolved.didRefresh {
                let updatedConfig = configuration.withUpdatedActiveBookmark(resolved.bookmarkData)
                saveConfiguration(updatedConfig)
                Logger.info("Refreshed stale bookmark for screen \(screenID)", category: .fileAccess)
            }

            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard canAccess else {
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    return true
                }
                Logger.error("Cannot access file for screen \(screenID)", category: .fileAccess)
                return false
            }
            return true

        case .failure(let failure):
            Logger.error("Failed to resolve bookmark for screen \(screenID): \(failure.localizedDescription)", category: .fileAccess)
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
        switch SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient) {
        case .success(let resolved):
            let url = resolved.url

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
                do {
                    let indexURL = try FolderURLSchemeHandler.resolvedFileURL(
                        for: requestURL,
                        inside: url
                    )
                    return FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false))
                } catch {
                    Logger.error("Failed to resolve HTML folder index for screen \(screenID): \(error.localizedDescription)", category: .fileAccess)
                    return false
                }
            }

            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))

        case .failure(let failure):
            Logger.error("Failed to resolve local HTML bookmark for screen \(screenID): \(failure.localizedDescription)", category: .fileAccess)
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
        Logger.info("Last used directory no longer exists: \(path)", category: .fileAccess)
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
    var exists: Bool {
        FileManager.default.fileExists(atPath: path(percentEncoded: false))
    }
}
