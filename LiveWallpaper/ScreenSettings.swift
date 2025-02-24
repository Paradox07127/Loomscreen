import Foundation
import CoreGraphics
import AppKit

struct ScreenConfiguration: Codable {
    let screenID: UInt32
    let videoBookmarkData: Data
    let playbackSpeed: Double
    let pauseOnBattery: Bool
    
    init(screenID: CGDirectDisplayID, videoBookmarkData: Data, playbackSpeed: Double = 1.0, pauseOnBattery: Bool = false) {
        self.screenID = screenID
        self.videoBookmarkData = videoBookmarkData
        self.playbackSpeed = playbackSpeed
        self.pauseOnBattery = pauseOnBattery
    }
}

struct GlobalSettings: Codable {
    var globalPauseOnBattery: Bool
    
    init(globalPauseOnBattery: Bool = true) {
        self.globalPauseOnBattery = globalPauseOnBattery
    }
}

class SettingsManager {
    static let shared = SettingsManager()
    private let screenConfigurationsKey = "screenConfigurations"
    private let globalSettingsKey = "globalSettings"
    
    private init() {}
    
    // MARK: - Screen Configurations
    func saveConfiguration(_ configuration: ScreenConfiguration) {
        var configurations = loadConfigurations()
        
        if let index = configurations.firstIndex(where: { $0.screenID == configuration.screenID }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }
        
        save(configurations)
    }
    
    func loadConfigurations() -> [ScreenConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: screenConfigurationsKey),
              let configurations = try? JSONDecoder().decode([ScreenConfiguration].self, from: data) else {
            return []
        }
        return configurations
    }
    
    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        return loadConfigurations().first { $0.screenID == screenID }
    }
    
    private func save(_ configurations: [ScreenConfiguration]) {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        UserDefaults.standard.set(data, forKey: screenConfigurationsKey)
    }
    
    // MARK: - Global Settings
    func saveGlobalSettings(_ settings: GlobalSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: globalSettingsKey)
    }
    
    func loadGlobalSettings() -> GlobalSettings {
        guard let data = UserDefaults.standard.data(forKey: globalSettingsKey),
              let settings = try? JSONDecoder().decode(GlobalSettings.self, from: data) else {
            return GlobalSettings()
        }
        return settings
    }
    
    // MARK: - Clean Settings
    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        var configurations = loadConfigurations()
        configurations.removeAll { $0.screenID == screenID }
        save(configurations)
    }
    
    func cleanAllSettings() {
        UserDefaults.standard.removeObject(forKey: screenConfigurationsKey)
        UserDefaults.standard.removeObject(forKey: globalSettingsKey)
    }
}
