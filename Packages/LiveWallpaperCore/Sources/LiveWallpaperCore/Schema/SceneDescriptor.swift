import Foundation

/// Persisted Wallpaper Engine `.scene` content identifier. Saved inside
/// `WallpaperContent.scene(...)` so a scene wallpaper can be restored across
/// launches without re-extracting `scene.pkg` or asking the user to re-grant
/// access to the Steam Workshop folder.
///
/// `cacheRelativePath` is rooted under `Application Support/LiveWallpaper/`
/// (e.g. `wpe-cache/<workshopID>`); both the import service and the runtime
/// resolver re-validate the path before joining it onto the application
/// support directory, so a malformed persisted blob can never escape root.
public struct SceneDescriptor: Codable, Equatable, Sendable {
    public let workshopID: String
    /// Path beneath `Application Support/LiveWallpaper/` — must satisfy
    /// `WPEPathSafety.isSafeCacheRelativePath`.
    public let cacheRelativePath: String
    /// Where the runtime reads this scene's assets from. `.cache` (the default
    /// and the only value historical descriptors persist) is the legacy
    /// extracted `wpe-cache/<id>` directory; `.packageSource`/`.sourceDirectory`
    /// read in place from the import source so no second on-disk copy exists.
    public let assetStorage: SceneAssetStorage
    /// Entry filename inside the cache root, e.g. `scene.json`.
    public let entryFile: String
    /// Best-effort runtime capability assessment from the import flow.
    public let capabilityTier: SceneCapabilityTier
    /// Declared Workshop dependencies that may be mounted as sibling cache or
    /// source roots at runtime.
    public let dependencyWorkshopIDs: [String]
    /// Preflight tier from `WPEScenePreflight`. Optional so historical
    /// descriptors persisted before preflight existed still decode.
    public let preflightTier: WPEScenePreflightTier?
    /// Per-scene feature declarations from preflight. Sorted set kept as a
    /// `[String]` on disk for forward-compatibility — unknown future flags
    /// round-trip without the decoder rejecting the blob.
    public let preflightFeatureFlags: [WPESceneFeatureFlag]
    /// User-tunable values for `project.json -> general -> properties`.
    /// Keyed by the property name (e.g. `schemecolor`). Empty for a freshly
    /// imported scene; populated as the user adjusts the right-hand
    /// inspector. Persisted so settings survive relaunch.
    public let propertyOverrides: [String: WallpaperEngineProjectPropertyValue]

    public init(
        workshopID: String,
        cacheRelativePath: String,
        entryFile: String,
        capabilityTier: SceneCapabilityTier,
        assetStorage: SceneAssetStorage = .cache,
        dependencyWorkshopIDs: [String] = [],
        preflightTier: WPEScenePreflightTier? = nil,
        preflightFeatureFlags: [WPESceneFeatureFlag] = [],
        propertyOverrides: [String: WallpaperEngineProjectPropertyValue] = [:]
    ) {
        self.workshopID = workshopID
        self.cacheRelativePath = cacheRelativePath
        self.entryFile = entryFile
        self.capabilityTier = capabilityTier
        self.assetStorage = assetStorage
        self.dependencyWorkshopIDs = dependencyWorkshopIDs
        self.preflightTier = preflightTier
        self.preflightFeatureFlags = preflightFeatureFlags
        self.propertyOverrides = propertyOverrides
    }

    /// Returns a copy of the descriptor with the named property override
    /// set to the supplied value (or cleared when `value == nil`).
    public func updating(
        property key: String,
        to value: WallpaperEngineProjectPropertyValue?
    ) -> SceneDescriptor {
        var next = propertyOverrides
        if let value {
            next[key] = value
        } else {
            next.removeValue(forKey: key)
        }
        return SceneDescriptor(
            workshopID: workshopID,
            cacheRelativePath: cacheRelativePath,
            entryFile: entryFile,
            capabilityTier: capabilityTier,
            assetStorage: assetStorage,
            dependencyWorkshopIDs: dependencyWorkshopIDs,
            preflightTier: preflightTier,
            preflightFeatureFlags: preflightFeatureFlags,
            propertyOverrides: next
        )
    }

    /// Returns a copy with every override cleared.
    public func clearingPropertyOverrides() -> SceneDescriptor {
        SceneDescriptor(
            workshopID: workshopID,
            cacheRelativePath: cacheRelativePath,
            entryFile: entryFile,
            capabilityTier: capabilityTier,
            assetStorage: assetStorage,
            dependencyWorkshopIDs: dependencyWorkshopIDs,
            preflightTier: preflightTier,
            preflightFeatureFlags: preflightFeatureFlags,
            propertyOverrides: [:]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case workshopID
        case cacheRelativePath
        case entryFile
        case capabilityTier
        case assetStorage
        case dependencyWorkshopIDs
        case preflightTier
        case preflightFeatureFlags
        case propertyOverrides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workshopID = try c.decode(String.self, forKey: .workshopID)
        cacheRelativePath = try c.decode(String.self, forKey: .cacheRelativePath)
        entryFile = try c.decode(String.self, forKey: .entryFile)
        capabilityTier = (try? c.decode(SceneCapabilityTier.self, forKey: .capabilityTier)) ?? .unsupported
        assetStorage = (try? c.decodeIfPresent(SceneAssetStorage.self, forKey: .assetStorage)) ?? .cache
        dependencyWorkshopIDs = (try? c.decodeIfPresent([String].self, forKey: .dependencyWorkshopIDs)) ?? []
        preflightTier = try? c.decodeIfPresent(WPEScenePreflightTier.self, forKey: .preflightTier)
        let rawFlags = (try? c.decodeIfPresent([String].self, forKey: .preflightFeatureFlags)) ?? []
        preflightFeatureFlags = rawFlags.compactMap(WPESceneFeatureFlag.init(rawValue:))
        propertyOverrides = (try? c.decodeIfPresent(
            [String: WallpaperEngineProjectPropertyValue].self,
            forKey: .propertyOverrides
        )) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workshopID, forKey: .workshopID)
        try c.encode(cacheRelativePath, forKey: .cacheRelativePath)
        try c.encode(entryFile, forKey: .entryFile)
        try c.encode(capabilityTier, forKey: .capabilityTier)
        if assetStorage != .cache {
            try c.encode(assetStorage, forKey: .assetStorage)
        }
        try c.encode(dependencyWorkshopIDs, forKey: .dependencyWorkshopIDs)
        try c.encodeIfPresent(preflightTier, forKey: .preflightTier)
        try c.encode(preflightFeatureFlags.map(\.rawValue), forKey: .preflightFeatureFlags)
        if !propertyOverrides.isEmpty {
            try c.encode(propertyOverrides, forKey: .propertyOverrides)
        }
    }
}

/// Phase 2.0 capability gate. Computed by the import service after parsing
/// `scene.json`; persisted so the runtime can short-circuit obviously
/// degraded scenes without re-walking the JSON.
public enum SceneCapabilityTier: String, Codable, Equatable, Sendable {
    /// All declared objects render via the image-only pipeline.
    case imageOnly
    /// Some objects are renderable but at least one is missing assets or
    /// uses unsupported features. Runtime still mounts the scene.
    case degraded
    /// No object can render — UI must fall back to the placeholder card.
    case unsupported

    public var localizedLabel: String {
        switch self {
        case .imageOnly:
            return String(localized: "Image-only", defaultValue: "Image-only", comment: "Wallpaper Engine scene capability tier.")
        case .degraded:
            return String(localized: "Degraded", defaultValue: "Degraded", comment: "Wallpaper Engine scene capability tier.")
        case .unsupported:
            return String(localized: "Unsupported", defaultValue: "Unsupported", comment: "Wallpaper Engine scene capability tier.")
        }
    }
}

/// Where a scene's runtime assets are read from. Persisted inside
/// `SceneDescriptor`; absent in historical blobs, which decode as `.cache`.
public enum SceneAssetStorage: Codable, Equatable, Sendable {
    /// Legacy: assets extracted into `wpe-cache/<id>` (a second on-disk copy).
    case cache
    /// Read in place from the import source folder (folder imports).
    case sourceDirectory
    /// Read in place from a packed `scene.pkg` in the import source. `fileName`
    /// is the archive's name within the source root (typically `scene.pkg`).
    case packageSource(fileName: String)
}
