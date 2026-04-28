import Foundation
import CoreGraphics

/// Centralized per-screen wallpaper configuration store.
/// Owns the in-memory cache and delegates persistence to `SettingsManager`.
@MainActor
final class WallpaperConfigurationStore {
    private var cache: [CGDirectDisplayID: ScreenConfiguration] = [:]

    func get(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        if let cached = cache[screenID] {
            return cached
        }

        guard let configuration = SettingsManager.shared.getConfiguration(for: screenID) else {
            return nil
        }

        cache[screenID] = configuration
        return configuration
    }

    func save(_ config: ScreenConfiguration) {
        cache[config.screenID] = config
        SettingsManager.shared.saveConfiguration(config)
    }

    func remove(for screenID: CGDirectDisplayID) {
        cache.removeValue(forKey: screenID)
        SettingsManager.shared.cleanSettingsForScreen(screenID)
    }

    func clearCache() {
        cache.removeAll()
    }

    func allScreenIDs() -> [CGDirectDisplayID] {
        loadAll().map(\.screenID)
    }

    func loadAll() -> [ScreenConfiguration] {
        let configs = SettingsManager.shared.loadConfigurations()
        cache = Dictionary(uniqueKeysWithValues: configs.map { ($0.screenID, $0) })
        return configs
    }

    func pruneInvalidVideoConfigurations(using validator: (CGDirectDisplayID) -> Bool) -> [CGDirectDisplayID] {
        // Snapshot IDs first; validation may refresh stale bookmarks.
        let candidateVideoIDs = SettingsManager.shared
            .loadConfigurations()
            .filter { $0.wallpaperType == .video }
            .map(\.screenID)

        // 2. Run the validator (side-effect: may refresh stale bookmarks).
        let invalidVideoIDs = Set(candidateVideoIDs.filter { !validator($0) })

        guard !invalidVideoIDs.isEmpty else {
            // Rehydrate cache so any bookmark refreshes performed by the
            // validator are visible to subsequent reads.
            _ = loadAll()
            return []
        }

        // Re-read so bookmark refreshes survive the rewrite.
        let postValidationConfigs = SettingsManager.shared.loadConfigurations()

        let pruned = Self.removingInvalidVideoConfigurations(
            from: postValidationConfigs,
            invalidScreenIDs: invalidVideoIDs
        )

        cache = Dictionary(uniqueKeysWithValues: pruned.map { ($0.screenID, $0) })
        SettingsManager.shared.replaceAllConfigurations(pruned)

        return Array(invalidVideoIDs)
    }

    nonisolated static func removingInvalidVideoConfigurations(
        from configs: [ScreenConfiguration],
        invalidScreenIDs: Set<CGDirectDisplayID>
    ) -> [ScreenConfiguration] {
        configs.filter { config in
            !(config.wallpaperType == .video && invalidScreenIDs.contains(config.screenID))
        }
    }
}
