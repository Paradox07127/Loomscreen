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
        cachedGlobalSettings = settings
        do {
            let data = try encoder.encode(settings)
            UserDefaults.standard.set(data, forKey: Keys.globalSettings)
            applyStartOnLoginSetting(settings.startOnLogin)
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

    func cleanAllSettings() {
        cachedGlobalSettings = nil
        cachedConfigurations = nil
        UserDefaults.standard.removeObject(forKey: Keys.screenConfigurations)
        UserDefaults.standard.removeObject(forKey: Keys.globalSettings)
        UserDefaults.standard.removeObject(forKey: Keys.aerialsDirectoryBookmark)
        applyStartOnLoginSetting(false)
    }
    
    // MARK: - Validation

    func validateConfiguration(for screenID: CGDirectDisplayID) -> Bool {
        guard let configuration = loadConfigurations().first(where: { $0.screenID == screenID }) else { return false }

        guard configuration.wallpaperType == .video else {
            return true
        }

        guard let bookmarkData = configuration.videoBookmarkData else {
            Logger.error("Missing video bookmark for active video wallpaper on screen \(screenID)", category: .fileAccess)
            return false
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            let canAccess = url.startAccessingSecurityScopedResource()
            if isStale && canAccess {
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
            } else {
                Logger.error("Cannot access file for screen \(screenID)", category: .fileAccess)
            }
            return canAccess
        } catch {
            Logger.error("Failed to resolve bookmark for screen \(screenID): \(error.localizedDescription)", category: .fileAccess)
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
}

// MARK: - URL Extension
extension URL {
    // Check if URL exists
    var exists: Bool {
        FileManager.default.fileExists(atPath: path(percentEncoded: false))
    }
}
