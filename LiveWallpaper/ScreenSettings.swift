import Foundation
import CoreGraphics

struct ScreenConfiguration: Codable {
    let screenID: UInt32  // CGDirectDisplayID is actually a UInt32
    let videoBookmarkData: Data
    let playbackSpeed: Double
    
    enum CodingKeys: String, CodingKey {
        case screenID
        case videoBookmarkData
        case playbackSpeed
    }
    
    init(screenID: CGDirectDisplayID, videoBookmarkData: Data, playbackSpeed: Double = 1.0) {
        self.screenID = screenID  // CGDirectDisplayID automatically bridges to UInt32
        self.videoBookmarkData = videoBookmarkData
        self.playbackSpeed = playbackSpeed
    }
    
    // Custom init from decoder to handle CGDirectDisplayID
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screenID = try container.decode(UInt32.self, forKey: .screenID)
        videoBookmarkData = try container.decode(Data.self, forKey: .videoBookmarkData)
        playbackSpeed = try container.decode(Double.self, forKey: .playbackSpeed)
    }
    
    // Custom encode function
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(screenID, forKey: .screenID)
        try container.encode(videoBookmarkData, forKey: .videoBookmarkData)
        try container.encode(playbackSpeed, forKey: .playbackSpeed)
    }
}

class SettingsManager {
    static let shared = SettingsManager()
    private let settingsKey = "screenConfigurations"
    
    private init() {}
    
    func saveConfiguration(_ configuration: ScreenConfiguration) {
        var configurations = loadConfigurations()
        
        // Update or add new configuration
        if let index = configurations.firstIndex(where: { $0.screenID == configuration.screenID }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }
        
        save(configurations)
    }
    
    func loadConfigurations() -> [ScreenConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let configurations = try? JSONDecoder().decode([ScreenConfiguration].self, from: data) else {
            return []
        }
        return configurations
    }
    
    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        return loadConfigurations().first { $0.screenID == screenID }
    }
    
    func removeConfiguration(for screenID: CGDirectDisplayID) {
        var configurations = loadConfigurations()
        configurations.removeAll { $0.screenID == screenID }
        save(configurations)
    }
    
    private func save(_ configurations: [ScreenConfiguration]) {
        guard let data = try? JSONEncoder().encode(configurations) else {
            return
        }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }
}
