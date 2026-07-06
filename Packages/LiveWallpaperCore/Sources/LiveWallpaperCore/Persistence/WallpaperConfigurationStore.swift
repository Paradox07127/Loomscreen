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

    /// Resolve by `CGDirectDisplayID` first; on miss, fall back to
    /// `displayFingerprint` and migrate the matched config to the current ID.
    public func get(
        for screenID: CGDirectDisplayID,
        fingerprint: String?
    ) -> ScreenConfiguration? {
        if let direct = get(for: screenID) {
            // ID hit but the cached config carries a *different, explicit*
            // fingerprint: macOS recycled this CGDirectDisplayID onto a
            // physically different panel. Trust the fingerprint, not the ID —
            // stamping it onto the old config would hand the previous panel's
            // wallpaper to the new one. Fall through to the fingerprint scan,
            // evicting the stale ID→config binding first.
            if let fingerprint, !fingerprint.isUnknownDisplayFingerprint,
               let cachedFingerprint = direct.displayFingerprint,
               !cachedFingerprint.isUnknownDisplayFingerprint,
               cachedFingerprint != fingerprint {
                cache.removeValue(forKey: screenID)
                return migrateByFingerprint(to: screenID, fingerprint: fingerprint)
            }
            // Cached fingerprint missing/unknown: lenient reuse — back-fill the
            // now-known fingerprint onto the same config.
            if let fingerprint, !fingerprint.isUnknownDisplayFingerprint,
               direct.displayFingerprint != fingerprint {
                var stamped = direct
                stamped.displayFingerprint = fingerprint
                save(stamped)
                return stamped
            }
            return direct
        }

        guard let fingerprint, !fingerprint.isUnknownDisplayFingerprint else {
            return nil
        }

        return migrateByFingerprint(to: screenID, fingerprint: fingerprint)
    }

    private func migrateByFingerprint(
        to screenID: CGDirectDisplayID,
        fingerprint: String
    ) -> ScreenConfiguration? {
        let all = persistence.loadConfigurations()
        guard var match = all.first(where: { $0.displayFingerprint == fingerprint }) else {
            return nil
        }
        let oldScreenID = match.screenID
        match.screenID = screenID
        match.displayFingerprint = fingerprint
        save(match)
        if oldScreenID != screenID {
            persistence.cleanSettingsForScreen(oldScreenID)
            cache.removeValue(forKey: oldScreenID)
        }
        return match
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
        case .monitor:
            // No external resource bookmark to validate — the dashboard is a
            // bundled page, and the optional Claude/Codex roots have their own
            // security-scoped bookmarks whose absence only degrades health.
            return false
        }
    }
}
