import Foundation
import CoreGraphics

/// Persistence seam — production wires this through SettingsManager,
/// tests inject in-memory stores.
@MainActor
public protocol ScreenConfigurationPersisting {
    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration?
    func saveConfiguration(_ configuration: ScreenConfiguration)
    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID)
    func loadConfigurations() -> [ScreenConfiguration]
    func replaceAllConfigurations(_ configurations: [ScreenConfiguration])
}

/// Centralized per-screen wallpaper configuration store.
/// Owns the in-memory cache; delegates persistence through the injected
/// protocol so Core stays free of the SettingsManager (UserDefaults) layer.
@MainActor
public final class WallpaperConfigurationStore {
    private var cache: [CGDirectDisplayID: ScreenConfiguration] = [:]
    private let persistence: any ScreenConfigurationPersisting

    public init(persistence: any ScreenConfigurationPersisting) {
        self.persistence = persistence
    }

    public func get(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        if let cached = cache[screenID] {
            return cached
        }

        guard let configuration = persistence.getConfiguration(for: screenID) else {
            return nil
        }

        cache[screenID] = configuration
        return configuration
    }

    public func save(_ config: ScreenConfiguration) {
        cache[config.screenID] = config
        persistence.saveConfiguration(config)
    }

    public func remove(for screenID: CGDirectDisplayID) {
        cache.removeValue(forKey: screenID)
        persistence.cleanSettingsForScreen(screenID)
    }

    public func clearCache() {
        cache.removeAll()
    }

    public func allScreenIDs() -> [CGDirectDisplayID] {
        loadAll().map(\.screenID)
    }

    public func loadAll() -> [ScreenConfiguration] {
        let configs = persistence.loadConfigurations()
        cache = Dictionary(uniqueKeysWithValues: configs.map { ($0.screenID, $0) })
        return configs
    }

    public func pruneInvalidResourceConfigurations(using validator: (CGDirectDisplayID) -> Bool) -> [CGDirectDisplayID] {
        let candidateIDs = persistence
            .loadConfigurations()
            .filter(Self.requiresResourceValidation)
            .map(\.screenID)

        let invalidIDs = Set(candidateIDs.filter { !validator($0) })

        guard !invalidIDs.isEmpty else {
            _ = loadAll()
            return []
        }

        let postValidationConfigs = persistence.loadConfigurations()
        let pruned = Self.removingInvalidResourceConfigurations(
            from: postValidationConfigs,
            invalidScreenIDs: invalidIDs
        )

        cache = Dictionary(uniqueKeysWithValues: pruned.map { ($0.screenID, $0) })
        persistence.replaceAllConfigurations(pruned)

        return Array(invalidIDs)
    }

    public nonisolated static func removingInvalidResourceConfigurations(
        from configs: [ScreenConfiguration],
        invalidScreenIDs: Set<CGDirectDisplayID>
    ) -> [ScreenConfiguration] {
        configs.filter { config in
            guard invalidScreenIDs.contains(config.screenID),
                  requiresResourceValidation(config) else {
                return true
            }
            return false
        }
    }

    nonisolated private static func requiresResourceValidation(_ config: ScreenConfiguration) -> Bool {
        guard let definition = WallpaperSessionDefinition(configuration: config) else {
            return true
        }

        switch definition {
        case .video:
            return true
        case .html(let source, _):
            if case .file = source { return true }
            if case .folder = source { return true }
            return false
        case .metalShader:
            return false
        case .scene:
            return false
        }
    }
}
