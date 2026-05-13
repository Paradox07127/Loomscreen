import Foundation
import CoreGraphics
import AppKit
import AVFoundation
import ServiceManagement

@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedGlobalSettings: GlobalSettings?
    private var cachedConfigurations: [ScreenConfiguration]?

    private enum Keys {
        static let screenConfigurations = "screenConfigurations"
        static let globalSettings = "globalSettings"
        static let lastUsedDirectory = "lastUsedDirectory"
        static let aerialsDirectoryBookmark = "AerialsLibrary.DirectoryBookmark"
        static let bookmarks = "WallpaperBookmarks.v1"
        static let trustedHosts = "TrustedHTMLHosts.v1"
        static let workshopLibraryRootBookmark = "WPELibrary.RootBookmark.v1"
        static let appLanguage = AppLanguagePreference.storageKey
    }

    // MARK: - Screen Configurations

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        var configs = loadConfigurations()
        if let index = configs.firstIndex(where: { $0.screenID == configuration.screenID }) {
            configs[index] = configuration
        } else {
            configs.append(configuration)
        }
        cachedConfigurations = configs
        persistConfigurations(configs)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        cachedConfigurations = configurations
        persistConfigurations(configurations)
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        if let cached = cachedConfigurations { return cached }
        guard let data = UserDefaults.standard.data(forKey: Keys.screenConfigurations) else { return [] }
        do {
            let configs = try decoder.decode([ScreenConfiguration].self, from: data)
            cachedConfigurations = configs
            return configs
        } catch {
            Logger.error("Failed to decode screen configurations: \(error.localizedDescription)", category: .settings)
            return []
        }
    }

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        loadConfigurations().first { $0.screenID == screenID }
    }

    private func persistConfigurations(_ configs: [ScreenConfiguration]) {
        do {
            let data = try encoder.encode(configs)
            UserDefaults.standard.set(data, forKey: Keys.screenConfigurations)
        } catch {
            Logger.error("Failed to encode screen configurations: \(error.localizedDescription)", category: .settings)
        }
    }
    
    // MARK: - Global Settings

    func saveGlobalSettings(_ settings: GlobalSettings) {
        let previousStartOnLogin = cachedGlobalSettings?.startOnLogin ?? loadGlobalSettings().startOnLogin
        cachedGlobalSettings = settings
        do {
            let data = try encoder.encode(settings)
            UserDefaults.standard.set(data, forKey: Keys.globalSettings)
            if previousStartOnLogin != settings.startOnLogin {
                applyStartOnLoginSetting(settings.startOnLogin)
            }
            Logger.settingsChanged(setting: "globalSettings", value: "Updated global settings")
        } catch {
            Logger.error("Failed to encode global settings: \(error.localizedDescription)", category: .settings)
        }
    }

    func loadGlobalSettings() -> GlobalSettings {
        if let cached = cachedGlobalSettings { return cached }
        guard let data = UserDefaults.standard.data(forKey: Keys.globalSettings) else {
            let defaults = GlobalSettings()
            cachedGlobalSettings = defaults
            return defaults
        }
        do {
            let settings = try decoder.decode(GlobalSettings.self, from: data)
            cachedGlobalSettings = settings
            return settings
        } catch {
            Logger.error("Failed to decode global settings: \(error.localizedDescription)", category: .settings)
            let defaults = GlobalSettings()
            cachedGlobalSettings = defaults
            return defaults
        }
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
        UserDefaults.standard.removeObject(forKey: Keys.screenConfigurations)
        UserDefaults.standard.removeObject(forKey: Keys.globalSettings)
        UserDefaults.standard.removeObject(forKey: Keys.aerialsDirectoryBookmark)
        UserDefaults.standard.removeObject(forKey: Keys.bookmarks)
        UserDefaults.standard.removeObject(forKey: Keys.trustedHosts)
        UserDefaults.standard.removeObject(forKey: Keys.workshopLibraryRootBookmark)
        UserDefaults.standard.removeObject(forKey: Keys.appLanguage)
        BookmarkStore.shared.resetAfterSettingsCleared()
        TrustedHostStore.shared.resetAfterSettingsCleared()
        if applyLoginSetting {
            applyStartOnLoginSetting(false)
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
        guard let data = UserDefaults.standard.data(forKey: Keys.bookmarks) else { return [] }
        do {
            return try decoder.decode([WallpaperBookmark].self, from: data)
        } catch {
            Logger.error("Failed to decode wallpaper bookmarks: \(error.localizedDescription)", category: .settings)
            return []
        }
    }

    func saveWallpaperBookmarks(_ bookmarks: [WallpaperBookmark]) {
        do {
            let data = try encoder.encode(bookmarks)
            UserDefaults.standard.set(data, forKey: Keys.bookmarks)
        } catch {
            Logger.error("Failed to encode wallpaper bookmarks: \(error.localizedDescription)", category: .settings)
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
