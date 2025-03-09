import Foundation
import CoreGraphics
import AppKit
import AVFoundation

// Configuration for a single screen's video wallpaper
struct ScreenConfiguration: Codable, Equatable {
    let screenID: UInt32
    let videoBookmarkData: Data
    let playbackSpeed: Double
    let fitMode: VideoFitMode
    let pauseOnBattery: Bool
    let frameRateLimit: FrameRateLimit
    
    init(
        screenID: CGDirectDisplayID,
        videoBookmarkData: Data,
        playbackSpeed: Double = 1.0,
        fitMode: VideoFitMode = .aspectFill,
        pauseOnBattery: Bool = false,
        frameRateLimit: FrameRateLimit = .fps60
    ) {
        self.screenID = screenID
        self.videoBookmarkData = videoBookmarkData
        self.playbackSpeed = playbackSpeed
        self.fitMode = fitMode
        self.pauseOnBattery = pauseOnBattery
        self.frameRateLimit = frameRateLimit
    }
    
    static func == (lhs: ScreenConfiguration, rhs: ScreenConfiguration) -> Bool {
        lhs.screenID == rhs.screenID &&
        lhs.videoBookmarkData == rhs.videoBookmarkData &&
        lhs.playbackSpeed == rhs.playbackSpeed &&
        lhs.fitMode == rhs.fitMode &&
        lhs.pauseOnBattery == rhs.pauseOnBattery &&
        lhs.frameRateLimit == rhs.frameRateLimit
    }
}

// Video fit modes
enum VideoFitMode: String, Codable, CaseIterable, Identifiable {
    case aspectFill = "Fill"
    case aspectFit = "Fit"
    case stretch = "Stretch"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .aspectFill: return "Fill screen (may crop video)"
        case .aspectFit: return "Fit entire video (may show borders)"
        case .stretch: return "Stretch to fill screen (may distort)"
        }
    }
    
    var iconName: String {
        switch self {
        case .aspectFill: return "rectangle.fill"
        case .aspectFit: return "rectangle"
        case .stretch: return "arrow.up.left.and.arrow.down.right"
        }
    }
    
    var avLayerVideoGravity: AVLayerVideoGravity {
        switch self {
        case .aspectFill: return .resizeAspectFill
        case .aspectFit: return .resizeAspect
        case .stretch: return .resize
        }
    }
}

// Global application settings
struct GlobalSettings: Codable {
    var globalPauseOnBattery: Bool
    var preservePlaybackOnLock: Bool
    var startOnLogin: Bool
    var minimumBatteryLevel: Double?
    var defaultFrameRateLimit: FrameRateLimit
    
    init(
            globalPauseOnBattery: Bool = true,
            preservePlaybackOnLock: Bool = false,
            startOnLogin: Bool = false,
            minimumBatteryLevel: Double? = nil,
            defaultFrameRateLimit: FrameRateLimit = .fps60
        ) {
            self.globalPauseOnBattery = globalPauseOnBattery
            self.preservePlaybackOnLock = preservePlaybackOnLock
            self.startOnLogin = startOnLogin
            self.minimumBatteryLevel = minimumBatteryLevel
            self.defaultFrameRateLimit = defaultFrameRateLimit
        }
}

// Manager for persisting and retrieving settings
class SettingsManager {
    static let shared = SettingsManager()
    private let screenConfigurationsKey = "screenConfigurations"
    private let globalSettingsKey = "globalSettings"
    private let lastUsedDirectoryKey = "lastUsedDirectory"
    private let settingsLock = NSLock()
    
    private init() {
        migrateSettingsIfNeeded()
    }
    
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
        // In a real implementation, this would add/remove the app from login items
        // For macOS, this typically involves using the ServiceManagement framework
        // or LaunchServices API to add the app to login items
        Logger.debug("Setting 'Start at Login' to \(startOnLogin)", category: .settings)
        
        // Sample implementation using LaunchServices API would go here
        // This is a placeholder for the actual implementation
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
    
    // MARK: - Settings Migration
    
    private func migrateSettingsIfNeeded() {
        // Check for old version settings and migrate if needed
        if needsMigration() {
            Logger.notice("Migrating settings to new format", category: .settings)
            migrateSettings()
        }
    }
    
    private func needsMigration() -> Bool {
        // Check if settings need migration based on version or structure
        // This is a placeholder for actual migration detection logic
        return false
    }
    
    private func migrateSettings() {
        // Implement migration logic here
        // This would handle converting older setting formats to newer ones
    }
    
    // MARK: - Backup and Restore
    
    // Export settings to a file
    func exportSettings(to url: URL) -> Bool {
        Logger.info("Exporting settings to \(url.lastPathComponent)", category: .settings)
        
        settingsLock.lock()
        let configurations = loadConfigurationsUnsafe()
        let globalSettings = loadGlobalSettings()
        settingsLock.unlock()
        
        // Create export data structure
        let exportData = SettingsExport(
            configurations: configurations,
            globalSettings: globalSettings,
            exportDate: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(exportData)
            try data.write(to: url)
            Logger.info("Settings exported successfully", category: .settings)
            return true
        } catch {
            Logger.error("Failed to export settings: \(error.localizedDescription)", category: .settings)
            return false
        }
    }
    
    // Import settings from a file
    func importSettings(from url: URL) -> Bool {
        Logger.info("Importing settings from \(url.lastPathComponent)", category: .settings)
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let importData = try decoder.decode(SettingsExport.self, from: data)
            
            settingsLock.lock()
            defer { settingsLock.unlock() }
            
            // Apply imported settings
            saveUnsafe(importData.configurations)
            
            do {
                let globalSettingsData = try JSONEncoder().encode(importData.globalSettings)
                UserDefaults.standard.set(globalSettingsData, forKey: globalSettingsKey)
            } catch {
                Logger.error("Failed to save imported global settings: \(error.localizedDescription)", category: .settings)
            }
            
            Logger.info("Settings imported successfully (from app version \(importData.appVersion))", category: .settings)
            return true
        } catch {
            Logger.error("Failed to import settings: \(error.localizedDescription)", category: .settings)
            return false
        }
    }
}

// MARK: - Settings Export Structure
struct SettingsExport: Codable {
    let configurations: [ScreenConfiguration]
    let globalSettings: GlobalSettings
    let exportDate: Date
    let appVersion: String
}

// MARK: - URL Extension
extension URL {
    // Check if URL exists
    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
