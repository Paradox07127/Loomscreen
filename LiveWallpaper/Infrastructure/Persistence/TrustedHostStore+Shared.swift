import Foundation
import LiveWallpaperCore

/// Wires the shared trusted-host store to app settings persistence.
@MainActor
struct SettingsManagerTrustedHostPersistence: TrustedHostPersisting {
    func load() -> [String] { SettingsManager.shared.loadTrustedHosts() }
    func save(_ origins: [String]) { SettingsManager.shared.saveTrustedHosts(origins) }
}

extension TrustedHostStore {
    /// Shared app-wide trusted-host store.
    static let shared = TrustedHostStore(persistence: SettingsManagerTrustedHostPersistence())
}
