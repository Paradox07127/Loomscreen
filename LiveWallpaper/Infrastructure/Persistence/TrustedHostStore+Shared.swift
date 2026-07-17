import Foundation
import LiveWallpaperCore

/// Main-app singletons that reach into `SettingsManager`. The Core type
/// (TrustedHostStore + TrustedHostPersisting) lives in LiveWallpaperCore;
/// this file wires it to the legacy `SettingsManager.shared` bridge.
@MainActor
struct SettingsManagerTrustedHostPersistence: TrustedHostPersisting {
    func load() -> [String] { SettingsManager.shared.loadTrustedHosts() }
    func save(_ origins: [String]) { SettingsManager.shared.saveTrustedHosts(origins) }
}

extension TrustedHostStore {
    /// Shared, app-wide instance backed by the SettingsManager persistence
    /// adapter. Lite will replace this with a SKU-specific singleton.
    static let shared = TrustedHostStore(persistence: SettingsManagerTrustedHostPersistence())
}
