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
    private var cachedWallpaperBookmarks: [WallpaperBookmark]?

    /// Three big JSON blobs that used to live in `UserDefaults`. Moved to
    /// `~/Library/Application Support/<bundle-id>/Configuration/` so writes
    /// are observable, atomic, and independent of `cfprefsd`. Small
    /// primitives (language, bookmarks for single folders, trusted hosts)
    /// remain in `UserDefaults` because they're boot-critical and tiny.
    private let screenConfigStore: AtomicFileStore<[ScreenConfiguration]>
    private let globalSettingsStore: AtomicFileStore<GlobalSettings>
    private let wallpaperBookmarksStore: AtomicFileStore<[WallpaperBookmark]>

    /// Serial off-MainActor writer for all three file stores (configs, global
    /// settings, bookmarks). Cache mutations remain synchronous on MainActor;
    /// disk encode/fsync/rename are queued to this actor so toggle/slider/save
    /// handlers return immediately instead of blocking the UI per write.
    private let configurationPersistenceActor: WallpaperPersistenceActor

    /// Per-store monotonic counters: the actor drops any submission whose
    /// generation is older than the last it committed, so a stale in-flight
    /// write can't overwrite a newer MainActor mutation (or resurrect a reset).
    private var configurationWriteGeneration: UInt64 = 0
    private var globalSettingsWriteGeneration: UInt64 = 0
    private var bookmarksWriteGeneration: UInt64 = 0
    private var loginItemValidationGeneration: UInt64 = 0

    private enum Keys {
        static let screenConfigurations = "screenConfigurations"
        static let globalSettings = "globalSettings"
        static let lastUsedDirectory = "lastUsedDirectory"
        static let aerialsDirectoryBookmark = "AerialsLibrary.DirectoryBookmark"
        static let bookmarks = "WallpaperBookmarks.v1"
        static let trustedHosts = "TrustedHTMLHosts.v1"
        static let workshopLibraryRootBookmark = "WPELibrary.RootBookmark.v1"
        static let wpeEngineAssetsRootBookmark = "WPEEngineAssets.RootBookmark.v1"
        /// Set only when the engine assets came from the in-app SteamCMD download
        /// (the pruned container install). Presence = the managed install is the
        /// active engine-assets root; the value is its Steam `buildid` for update
        /// checks. Cleared when the user forgets/removes or manually links elsewhere.
        static let wpeEngineAssetsManagedBuildID = "WPEEngineAssets.ManagedBuildID.v1"
        static let appLanguage = AppLanguagePreference.storageKey
        /// Bumped each time we successfully migrate a blob out of UserDefaults
        /// into the file store. Lets us run the migration at most once even
        /// though we keep the legacy keys for one version as a compatibility
        /// buffer.
        static let configMigrationVersion = "Settings.MigrationVersion"
        /// Separate from `configMigrationVersion` (that one only gates the
        /// one-time UserDefaults→file move). This tracks the in-blob Codable
        /// shape of `GlobalSettings`/`ScreenConfiguration` themselves, so a
        /// future breaking schema change has a real stored baseline to
        /// compare against instead of assuming every install starts at 0.
        static let blobSchemaVersion = "Settings.BlobSchemaVersion"
    }

    /// Current migration revision. Bump when introducing a new file-backed
    /// store or schema change so the migration path re-runs on next launch.
    private static let currentMigrationVersion = 1

    /// Current in-blob schema revision. No transform runs today — this only
    /// stamps the baseline forward each launch — but a future breaking
    /// `GlobalSettings`/`ScreenConfiguration` change bumps this and adds a
    /// dispatch in `stampBlobSchemaVersionIfNeeded` keyed off `storedVersion`.
    private static let currentBlobSchemaVersion = 1

    init(directory: ConfigurationDirectory = ConfigurationDirectory()) {
        let screenConfigStore = AtomicFileStore<[ScreenConfiguration]>(
            fileURL: directory.url(for: .screenConfigurations)
        )
        self.screenConfigStore = screenConfigStore
        let globalSettingsStore = AtomicFileStore<GlobalSettings>(
            fileURL: directory.url(for: .globalSettings)
        )
        let wallpaperBookmarksStore = AtomicFileStore<[WallpaperBookmark]>(
            fileURL: directory.url(for: .wallpaperBookmarks)
        )
        self.globalSettingsStore = globalSettingsStore
        self.wallpaperBookmarksStore = wallpaperBookmarksStore
        self.configurationPersistenceActor = WallpaperPersistenceActor(
            store: screenConfigStore,
            globalSettingsStore: globalSettingsStore,
            bookmarksStore: wallpaperBookmarksStore
        )

        migrateLegacyUserDefaultsIfNeeded()
        stampBlobSchemaVersionIfNeeded()
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

    /// Drains every store routed through the persistence actor before exit so the
    /// last MainActor commits (global settings, bookmarks, screen configs) are
    /// durable. Re-submitting the latest cached value with a fresh generation
    /// either commits the final state or is a no-op if an in-flight task already
    /// wrote it; the actor's per-store generation guard keeps writes ordered.
    func flushPendingConfigurationWrites() async {
        configurationWriteGeneration &+= 1
        let configGeneration = configurationWriteGeneration
        do {
            try await configurationPersistenceActor.write(loadConfigurations(), generation: configGeneration)
        } catch {
            Logger.error(
                "Final configuration flush failed: \(error.localizedDescription)",
                category: .settings
            )
        }

        if let settings = cachedGlobalSettings {
            globalSettingsWriteGeneration &+= 1
            let generation = globalSettingsWriteGeneration
            do {
                try await configurationPersistenceActor.writeGlobalSettings(settings, generation: generation)
            } catch {
                Logger.error("Final global-settings flush failed: \(error.localizedDescription)", category: .settings)
            }
        }

        if let bookmarks = cachedWallpaperBookmarks {
            bookmarksWriteGeneration &+= 1
            let generation = bookmarksWriteGeneration
            do {
                try await configurationPersistenceActor.writeBookmarks(bookmarks, generation: generation)
            } catch {
                Logger.error("Final bookmarks flush failed: \(error.localizedDescription)", category: .settings)
            }
        }
    }
    
    // MARK: - Global Settings

    /// Updates the in-memory cache (and login-item side effect) synchronously so
    /// MainActor readers see the new value immediately; the disk write is queued
    /// to the serial persistence actor so the fsync/rename never blocks the UI.
    func saveGlobalSettings(_ settings: GlobalSettings) {
        let previousStartOnLogin = cachedGlobalSettings?.startOnLogin ?? loadGlobalSettings().startOnLogin
        cachedGlobalSettings = settings
        if previousStartOnLogin != settings.startOnLogin {
            applyStartOnLoginSetting(settings.startOnLogin)
        }

        globalSettingsWriteGeneration &+= 1
        let generation = globalSettingsWriteGeneration
        Task { [weak self, configurationPersistenceActor] in
            do {
                try await configurationPersistenceActor.writeGlobalSettings(settings, generation: generation)
                Logger.settingsChanged(setting: "globalSettings", value: "Updated global settings")
            } catch {
                await MainActor.run {
                    guard let self,
                          self.globalSettingsWriteGeneration == generation else { return }
                    Logger.error("Failed to persist global settings: \(error.localizedDescription)", category: .settings)
                    self.cachedGlobalSettings = nil
                }
            }
        }
    }

    func loadGlobalSettings() -> GlobalSettings {
        if let cached = cachedGlobalSettings { return cached }
        let settings = globalSettingsStore.read() ?? GlobalSettings()
        cachedGlobalSettings = settings
        return settings
    }

    func loadDisplayDefaults() -> DisplayDefaults {
        loadGlobalSettings().displayDefaults
    }

    func saveDisplayDefaults(_ displayDefaults: DisplayDefaults) {
        var settings = loadGlobalSettings()
        settings.displayDefaults = displayDefaults
        saveGlobalSettings(settings)
    }

    // MARK: - Wallpaper Engine History (managed library, LRU-bounded)

    /// Upper bound on the managed library. Each entry embeds a security-scoped
    /// bookmark (~1–3 KB of JSON) and lives in the single `global-settings.json`
    /// blob, so this caps that blob's growth rather than guarding a real
    /// database. 200 covers a large hand-curated library; raise further (or move
    /// to a dedicated store) if the library is meant to be effectively unbounded.
    static let maxRecentWPEImports = 200

    /// `clearsDeleteTombstone`: pass `true` ONLY for an explicit user re-acquire
    /// (Browse re-download / "Import from folder…"). Passive records — applying a
    /// history entry to a screen, or the auto-import library scan — must leave the
    /// tombstone in place, or a still-present copy in the user's real
    /// (out-of-container) Steam library resurrects a deleted item on the next scan.
    func recordWPEImport(_ entry: WPEHistoryEntry, clearsDeleteTombstone: Bool = false) {
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
        if clearsDeleteTombstone {
            settings.deletedWorkshopIDs.removeAll { $0 == entry.origin.workshopID }
        }
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

    /// Steam `buildid` of the in-app-downloaded engine assets, or nil when no
    /// managed install is present. Setting it also notifies so the assets
    /// library re-resolves and the UI flips to "Linked".
    var wpeEngineAssetsManagedBuildID: String? {
        get { UserDefaults.standard.string(forKey: Keys.wpeEngineAssetsManagedBuildID) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: Keys.wpeEngineAssetsManagedBuildID)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.wpeEngineAssetsManagedBuildID)
            }
            NotificationCenter.default.post(name: .wpeEngineAssetsBookmarkDidChange, object: nil)
        }
    }

    private func applyStartOnLoginSetting(_ startOnLogin: Bool) {
        let service = SMAppService.mainApp
        loginItemValidationGeneration &+= 1
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

        if loginItemStatus(statusAfter, matches: startOnLogin) {
            return
        }

        scheduleLoginItemStatusValidation(targetEnabled: startOnLogin)
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

    private func loginItemStatus(_ status: SMAppService.Status, matches targetEnabled: Bool) -> Bool {
        switch (targetEnabled, status) {
        case (true, .enabled), (false, .notRegistered), (false, .notFound):
            return true
        default:
            return false
        }
    }

    private func scheduleLoginItemStatusValidation(targetEnabled: Bool) {
        loginItemValidationGeneration &+= 1
        let generation = loginItemValidationGeneration

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            guard let self, self.loginItemValidationGeneration == generation else { return }

            let status = SMAppService.mainApp.status
            Logger.debug("SMAppService delayedStatus=\(self.describe(status))", category: .settings)
            guard !self.loginItemStatus(status, matches: targetEnabled) else { return }

            switch (targetEnabled, status) {
            case (true, .requiresApproval):
                Logger.warning("Login item registered but requires user approval in System Settings", category: .settings)
                self.postLoginItemFailure(reason: .requiresApproval)
            case (true, .notRegistered), (true, .notFound):
                Logger.error("Login item register() returned without error but delayed status is \(self.describe(status)); app may not be in /Applications/ or signing is rejected", category: .settings)
                self.postLoginItemFailure(reason: .registrationSilentlyFailed)
            case (false, _):
                Logger.warning("Login item disable target=false but delayed status=\(self.describe(status))", category: .settings)
            default:
                break
            }
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
        cachedWallpaperBookmarks = []

        // Route deletes through the same serial actor with bumped generations so
        // an in-flight async write (older generation) can't resurrect the file
        // after the reset.
        configurationWriteGeneration &+= 1
        globalSettingsWriteGeneration &+= 1
        bookmarksWriteGeneration &+= 1
        let configGeneration = configurationWriteGeneration
        let globalGeneration = globalSettingsWriteGeneration
        let bookmarksGeneration = bookmarksWriteGeneration
        Task { [configurationPersistenceActor] in
            await configurationPersistenceActor.delete(generation: configGeneration)
            await configurationPersistenceActor.deleteGlobalSettings(generation: globalGeneration)
            await configurationPersistenceActor.deleteBookmarks(generation: bookmarksGeneration)
        }

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

    /// Reads the last-stamped in-blob schema version and advances it to
    /// `currentBlobSchemaVersion`. Today there is no transform to run (every
    /// decoder is `decodeIfPresent`-defensive), so this only establishes a
    /// real baseline; a future breaking change adds a `storedVersion <
    /// N` dispatch here before the final stamp, the same shape as
    /// `migrateLegacyUserDefaultsIfNeeded` above.
    private func stampBlobSchemaVersionIfNeeded() {
        let storedVersion = UserDefaults.standard.integer(forKey: Keys.blobSchemaVersion)
        guard storedVersion < Self.currentBlobSchemaVersion else { return }
        UserDefaults.standard.set(Self.currentBlobSchemaVersion, forKey: Keys.blobSchemaVersion)
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
        case .monitor:
            // Native SwiftUI board + self-contained config — always valid.
            return true
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
                Logger.error("Invalid remote HTML URL for screen \(screenID): unsupported scheme '\(url.scheme ?? "none")'", category: .fileAccess)
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
        if let cached = cachedWallpaperBookmarks { return cached }
        let bookmarks = wallpaperBookmarksStore.read() ?? []
        cachedWallpaperBookmarks = bookmarks
        return bookmarks
    }

    /// Cache is updated synchronously (so a subsequent `loadWallpaperBookmarks`
    /// can't read the not-yet-flushed disk copy); the write is queued async.
    func saveWallpaperBookmarks(_ bookmarks: [WallpaperBookmark]) {
        cachedWallpaperBookmarks = bookmarks
        bookmarksWriteGeneration &+= 1
        let generation = bookmarksWriteGeneration
        Task { [weak self, configurationPersistenceActor] in
            do {
                try await configurationPersistenceActor.writeBookmarks(bookmarks, generation: generation)
            } catch {
                await MainActor.run {
                    guard let self,
                          self.bookmarksWriteGeneration == generation else { return }
                    Logger.error("Failed to persist wallpaper bookmarks: \(error.localizedDescription)", category: .settings)
                    self.cachedWallpaperBookmarks = nil
                }
            }
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
