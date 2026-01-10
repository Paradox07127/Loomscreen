import Foundation
import CoreGraphics
import AppKit
import AVFoundation
import ServiceManagement

// Manager for persisting and retrieving settings
class SettingsManager {
    static let shared = SettingsManager()
    private let screenConfigurationsKey = "screenConfigurations"
    private let globalSettingsKey = "globalSettings"
    private let lastUsedDirectoryKey = "lastUsedDirectory"
    private let settingsLock = NSLock()
    
    // MARK: - Screen Configurations
    
    // Save a screen configuration
    func saveConfiguration(_ configuration: ScreenConfiguration) {
        Logger.debug("Saving configuration for screen \(configuration.screenID)", category: .settings)
        
        // Thread-safe access to settings
        settingsLock.lock()
        defer { settingsLock.unlock() }
        
        var configurations = loadConfigurationsUnsafe()
        
        if let index = configurations.firstIndex(where: { $0.screenID == configuration.screenID }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }
        
        saveUnsafe(configurations)
    }
    
    // Load all screen configurations (thread-safe)
    func loadConfigurations() -> [ScreenConfiguration] {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return loadConfigurationsUnsafe()
    }
    
    // Non-locked version for internal use
    private func loadConfigurationsUnsafe() -> [ScreenConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: screenConfigurationsKey) else {
            return []
        }
        
        do {
            let configurations = try JSONDecoder().decode([ScreenConfiguration].self, from: data)
            return configurations
        } catch {
            Logger.error("Failed to decode screen configurations: \(error.localizedDescription)", category: .settings)
            return []
        }
    }
    
    // Get configuration for a specific screen
    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        Logger.debug("Getting configuration for screen \(screenID)", category: .settings)
        settingsLock.lock()
        defer { settingsLock.unlock() }
        
        return loadConfigurationsUnsafe().first { $0.screenID == screenID }
    }
    
    private func saveUnsafe(_ configurations: [ScreenConfiguration]) {
        do {
            let data = try JSONEncoder().encode(configurations)
            UserDefaults.standard.set(data, forKey: screenConfigurationsKey)
        } catch {
            Logger.error("Failed to encode screen configurations: \(error.localizedDescription)", category: .settings)
        }
    }
    
    // MARK: - Global Settings
    
    // Save global application settings
    func saveGlobalSettings(_ settings: GlobalSettings) {
        Logger.debug("Saving global settings", category: .settings)
        settingsLock.lock()
        defer { settingsLock.unlock() }
        
        do {
            let data = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(data, forKey: globalSettingsKey)
            
            // Apply start on login setting
            applyStartOnLoginSetting(settings.startOnLogin)
            
            Logger.settingsChanged(setting: "globalSettings", value: "Updated global settings")
        } catch {
            Logger.error("Failed to encode global settings: \(error.localizedDescription)", category: .settings)
        }
    }
    
    // Load global application settings
    func loadGlobalSettings() -> GlobalSettings {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        
        guard let data = UserDefaults.standard.data(forKey: globalSettingsKey) else {
            return GlobalSettings()
        }
        
        do {
            let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
            return settings
        } catch {
            Logger.error("Failed to decode global settings: \(error.localizedDescription)", category: .settings)
            return GlobalSettings()
        }
    }
    
    private func applyStartOnLoginSetting(_ startOnLogin: Bool) {
        Logger.debug("Setting 'Start at Login' to \(startOnLogin)", category: .settings)

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

    /// Check if the app is currently set to start at login
    func isStartOnLoginEnabled() -> Bool {
        return SMAppService.mainApp.status == .enabled
    }
    
    // MARK: - Clean Settings
    
    // Clean settings for a specific screen
    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        Logger.debug("Cleaning settings for screen \(screenID)", category: .settings)
        
        settingsLock.lock()
        defer { settingsLock.unlock() }
        
        var configurations = loadConfigurationsUnsafe()
        configurations.removeAll { $0.screenID == screenID }
        saveUnsafe(configurations)
    }
    
    // Clean all settings
    func cleanAllSettings() {
        Logger.notice("Cleaning all settings", category: .settings)
        
        settingsLock.lock()
        defer { settingsLock.unlock() }
        
        UserDefaults.standard.removeObject(forKey: screenConfigurationsKey)
        UserDefaults.standard.removeObject(forKey: globalSettingsKey)
        
        // Make sure to remove from login items if previously enabled
        applyStartOnLoginSetting(false)
    }
    
    // MARK: - Validation
    
    // Validate a screen configuration
    func validateConfiguration(for screenID: CGDirectDisplayID) -> Bool {
        Logger.debug("Validating configuration for screen \(screenID)", category: .settings)
        
        settingsLock.lock()
        let configuration = loadConfigurationsUnsafe().first { $0.screenID == screenID }
        settingsLock.unlock()
        
        guard let configuration = configuration else {
            return false
        }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: configuration.videoBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            let canAccess = url.startAccessingSecurityScopedResource()
            
            if isStale {
                Logger.warning("Stale bookmark detected for screen \(screenID)", category: .fileAccess)
            }
            
            // Clean up regardless of result
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
    
    // Save the last used directory for file picker
    func saveLastUsedDirectory(_ url: URL) {
        Logger.debug("Saving last used directory: \(url.lastPathComponent)", category: .settings)
        UserDefaults.standard.set(url.path, forKey: lastUsedDirectoryKey)
    }
    
    // Get the last used directory for file picker
    func getLastUsedDirectory() -> URL? {
        if let path = UserDefaults.standard.string(forKey: lastUsedDirectoryKey) {
            let url = URL(fileURLWithPath: path)
            if url.exists {
                return url
            } else {
                Logger.warning("Last used directory no longer exists: \(path)", category: .fileAccess)
            }
        }
        return nil
    }
}

// MARK: - URL Extension
extension URL {
    // Check if URL exists
    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
