import Foundation
import CoreGraphics

/// Centralized configuration cache + persistence.
/// Wraps SettingsManager access and provides in-memory cache.
@MainActor
final class ConfigurationRepository {
    private var cache: [CGDirectDisplayID: ScreenConfiguration] = [:]

    func get(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        cache[screenID] ?? SettingsManager.shared.getConfiguration(for: screenID)
    }

    func save(_ config: ScreenConfiguration) {
        cache[config.screenID] = config
        SettingsManager.shared.saveConfiguration(config)
    }

    func remove(for screenID: CGDirectDisplayID) {
        cache.removeValue(forKey: screenID)
    }

    func allCachedScreenIDs() -> [CGDirectDisplayID] {
        Array(cache.keys)
    }

    func loadAll() -> [ScreenConfiguration] {
        let configs = SettingsManager.shared.loadConfigurations()
        for config in configs {
            cache[config.screenID] = config
        }
        return configs
    }
}
