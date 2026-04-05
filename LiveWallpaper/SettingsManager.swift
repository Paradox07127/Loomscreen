import Foundation
import CoreGraphics
import AppKit
import AVFoundation
import ServiceManagement

// Manager for persisting and retrieving settings
class SettingsManager {
    static let shared = SettingsManager()

    private enum Keys {
        static let screenConfigurations = "screenConfigurations"
        static let globalSettings = "globalSettings"
        static let lastUsedDirectory = "lastUsedDirectory"
    }

    private let settingsLock = NSLock()

    // MARK: - Thread-Safe Helper

    private func withLock<T>(_ operation: () -> T) -> T {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return operation()
    }

    // MARK: - Screen Configurations

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        withLock {
            var configurations = loadConfigurationsUnsafe()
            if let index = configurations.firstIndex(where: { $0.screenID == configuration.screenID }) {
                configurations[index] = configuration
            } else {
                configurations.append(configuration)
            }
            saveConfigurationsUnsafe(configurations)
        }
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        withLock { loadConfigurationsUnsafe() }
    }

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        return withLock { loadConfigurationsUnsafe().first { $0.screenID == screenID } }
    }

    // MARK: - Private Configuration Helpers

    private func loadConfigurationsUnsafe() -> [ScreenConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: Keys.screenConfigurations) else {
            return []
        }
        do {
            return try JSONDecoder().decode([ScreenConfiguration].self, from: data)
        } catch {
            Logger.error("Failed to decode screen configurations: \(error.localizedDescription)", category: .settings)
            return []
        }
    }

    private func saveConfigurationsUnsafe(_ configurations: [ScreenConfiguration]) {
        do {
            let data = try JSONEncoder().encode(configurations)
            UserDefaults.standard.set(data, forKey: Keys.screenConfigurations)
        } catch {
            Logger.error("Failed to encode screen configurations: \(error.localizedDescription)", category: .settings)
        }
    }
    
    // MARK: - Global Settings

    func saveGlobalSettings(_ settings: GlobalSettings) {
        withLock {
            do {
                let data = try JSONEncoder().encode(settings)
                UserDefaults.standard.set(data, forKey: Keys.globalSettings)
                applyStartOnLoginSetting(settings.startOnLogin)
                Logger.settingsChanged(setting: "globalSettings", value: "Updated global settings")
            } catch {
                Logger.error("Failed to encode global settings: \(error.localizedDescription)", category: .settings)
            }
        }
    }

    func loadGlobalSettings() -> GlobalSettings {
        withLock {
            guard let data = UserDefaults.standard.data(forKey: Keys.globalSettings) else {
                return GlobalSettings()
            }
            do {
                return try JSONDecoder().decode(GlobalSettings.self, from: data)
            } catch {
                Logger.error("Failed to decode global settings: \(error.localizedDescription)", category: .settings)
                return GlobalSettings()
            }
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
        withLock {
            var configurations = loadConfigurationsUnsafe()
            configurations.removeAll { $0.screenID == screenID }
            saveConfigurationsUnsafe(configurations)
        }
    }

    func cleanAllSettings() {
        Logger.notice("Cleaning all settings", category: .settings)
        withLock {
            UserDefaults.standard.removeObject(forKey: Keys.screenConfigurations)
            UserDefaults.standard.removeObject(forKey: Keys.globalSettings)
            applyStartOnLoginSetting(false)
        }
    }
    
    // MARK: - Validation

    func validateConfiguration(for screenID: CGDirectDisplayID) -> Bool {
        let configuration = withLock { loadConfigurationsUnsafe().first { $0.screenID == screenID } }
        guard let configuration = configuration else { return false }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: configuration.videoBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            let canAccess = url.startAccessingSecurityScopedResource()
            if isStale && canAccess {
                Logger.warning("Stale bookmark detected for screen \(screenID), refreshing", category: .fileAccess)
                // Regenerate the stale bookmark to prevent future access failures
                if let updatedBookmark = try? url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    let updatedConfig = configuration.withUpdatedBookmark(updatedBookmark)
                    withLock {
                        var configs = loadConfigurationsUnsafe()
                        if let index = configs.firstIndex(where: { $0.screenID == screenID }) {
                            configs[index] = updatedConfig
                            saveConfigurationsUnsafe(configs)
                        }
                    }
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
}

// MARK: - URL Extension
extension URL {
    // Check if URL exists
    var exists: Bool {
        FileManager.default.fileExists(atPath: path(percentEncoded: false))
    }
}
