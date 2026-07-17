import CoreGraphics
import Foundation
import LiveWallpaperCore

/// SettingsManager-backed `ScreenConfigurationPersisting` adapter. Stays in the
/// main target; the Core store class lives in
/// `LiveWallpaperCore/Persistence/WallpaperConfigurationStore.swift`.
@MainActor
struct SettingsManagerScreenConfigurationPersistence: ScreenConfigurationPersisting {
    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        SettingsManager.shared.getConfiguration(for: screenID)
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        SettingsManager.shared.saveConfiguration(configuration)
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        SettingsManager.shared.cleanSettingsForScreen(screenID)
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        SettingsManager.shared.loadConfigurations()
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        SettingsManager.shared.replaceAllConfigurations(configurations)
    }
}

extension WallpaperConfigurationStore {
    convenience init() {
        self.init(persistence: SettingsManagerScreenConfigurationPersistence())
    }
}
