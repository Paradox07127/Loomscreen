import Foundation
import CoreGraphics
import AppKit
import AVFoundation

/// Configuration for a single screen's video wallpaper
struct ScreenConfiguration: Codable, Equatable {
    let screenID: UInt32
    let videoBookmarkData: Data
    let playbackSpeed: Double
    let fitMode: VideoFitMode
    let pauseOnBattery: Bool
    
    init(
        screenID: CGDirectDisplayID,
        videoBookmarkData: Data,
        playbackSpeed: Double = 1.0,
        fitMode: VideoFitMode = .aspectFill,
        pauseOnBattery: Bool = false
    ) {
        self.screenID = screenID
        self.videoBookmarkData = videoBookmarkData
        self.playbackSpeed = playbackSpeed
        self.fitMode = fitMode
        self.pauseOnBattery = pauseOnBattery
    }
    
    static func == (lhs: ScreenConfiguration, rhs: ScreenConfiguration) -> Bool {
        lhs.screenID == rhs.screenID &&
        lhs.videoBookmarkData == rhs.videoBookmarkData &&
        lhs.playbackSpeed == rhs.playbackSpeed &&
        lhs.fitMode == rhs.fitMode &&
        lhs.pauseOnBattery == rhs.pauseOnBattery
    }
}

/// Video fit modes
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

/// Global application settings
struct GlobalSettings: Codable {
    var globalPauseOnBattery: Bool
    var preservePlaybackOnLock: Bool
    var startOnLogin: Bool
    var minimumBatteryLevel: Double?
    
    init(
        globalPauseOnBattery: Bool = true,
        preservePlaybackOnLock: Bool = false,
        startOnLogin: Bool = false,
        minimumBatteryLevel: Double? = nil
    ) {
        self.globalPauseOnBattery = globalPauseOnBattery
        self.preservePlaybackOnLock = preservePlaybackOnLock
        self.startOnLogin = startOnLogin
        self.minimumBatteryLevel = minimumBatteryLevel
    }
}

/// Manager for persisting and retrieving settings
class SettingsManager {
    static let shared = SettingsManager()
    private let screenConfigurationsKey = "screenConfigurations"
    private let globalSettingsKey = "globalSettings"
    
    private init() {}
    
    // MARK: - Screen Configurations
    
    /// Save a screen configuration
    func saveConfiguration(_ configuration: ScreenConfiguration) {
        var configurations = loadConfigurations()
        
        if let index = configurations.firstIndex(where: { $0.screenID == configuration.screenID }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }
        
        save(configurations)
    }
    
    /// Load all screen configurations
    func loadConfigurations() -> [ScreenConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: screenConfigurationsKey),
              let configurations = try? JSONDecoder().decode([ScreenConfiguration].self, from: data) else {
            return []
        }
        return configurations
    }
    
    /// Get configuration for a specific screen
    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        return loadConfigurations().first { $0.screenID == screenID }
    }
    
    private func save(_ configurations: [ScreenConfiguration]) {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        UserDefaults.standard.set(data, forKey: screenConfigurationsKey)
    }
    
    // MARK: - Global Settings
    
    /// Save global application settings
    func saveGlobalSettings(_ settings: GlobalSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: globalSettingsKey)
        
        // Apply start on login setting
        applyStartOnLoginSetting(settings.startOnLogin)
    }
    
    /// Load global application settings
    func loadGlobalSettings() -> GlobalSettings {
        guard let data = UserDefaults.standard.data(forKey: globalSettingsKey),
              let settings = try? JSONDecoder().decode(GlobalSettings.self, from: data) else {
            return GlobalSettings()
        }
        return settings
    }
    
    private func applyStartOnLoginSetting(_ startOnLogin: Bool) {
        // In a real implementation, this would add/remove the app from login items
        // For macOS, this typically involves using the ServiceManagement framework
        // and adding the app to login items
    }
    
    // MARK: - Clean Settings
    
    /// Clean settings for a specific screen
    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        var configurations = loadConfigurations()
        configurations.removeAll { $0.screenID == screenID }
        save(configurations)
    }
    
    /// Clean all settings
    func cleanAllSettings() {
        UserDefaults.standard.removeObject(forKey: screenConfigurationsKey)
        UserDefaults.standard.removeObject(forKey: globalSettingsKey)
        
        // Make sure to remove from login items if previously enabled
        applyStartOnLoginSetting(false)
    }
    
    // MARK: - Validation
    
    /// Validate a screen configuration
    func validateConfiguration(for screenID: CGDirectDisplayID) -> Bool {
        guard let configuration = getConfiguration(for: screenID) else {
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
            
            // Clean up regardless of result
            if canAccess {
                url.stopAccessingSecurityScopedResource()
            }
            
            return canAccess
        } catch {
            return false
        }
    }
    
    // MARK: - User Preferences
    
    // Save the last used directory for file picker
    func saveLastUsedDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "lastUsedDirectory")
    }
    
    // Get the last used directory for file picker
    func getLastUsedDirectory() -> URL? {
        if let path = UserDefaults.standard.string(forKey: "lastUsedDirectory") {
            let url = URL(fileURLWithPath: path)
            if url.exists {
                return url
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
