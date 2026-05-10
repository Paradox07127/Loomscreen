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
struct SceneDescriptor: Codable, Equatable, Sendable {
    let workshopID: String
    /// Path beneath `Application Support/LiveWallpaper/` — must satisfy
    /// `WPEPathSafety.isSafeCacheRelativePath`.
    let cacheRelativePath: String
    /// Entry filename inside the cache root, e.g. `scene.json`.
    let entryFile: String
    /// Best-effort runtime capability assessment from the import flow.
    let capabilityTier: SceneCapabilityTier
    /// Declared Workshop dependencies that may be mounted as sibling cache or
    /// source roots at runtime.
    let dependencyWorkshopIDs: [String]

    init(
        workshopID: String,
        cacheRelativePath: String,
        entryFile: String,
        capabilityTier: SceneCapabilityTier,
        dependencyWorkshopIDs: [String] = []
    ) {
        self.workshopID = workshopID
        self.cacheRelativePath = cacheRelativePath
        self.entryFile = entryFile
        self.capabilityTier = capabilityTier
        self.dependencyWorkshopIDs = dependencyWorkshopIDs
    }

    private enum CodingKeys: String, CodingKey {
        case workshopID
        case cacheRelativePath
        case entryFile
        case capabilityTier
        case dependencyWorkshopIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workshopID = try c.decode(String.self, forKey: .workshopID)
        cacheRelativePath = try c.decode(String.self, forKey: .cacheRelativePath)
        entryFile = try c.decode(String.self, forKey: .entryFile)
        // Lossy: an unrecognised tier (e.g. future Phase 2.x value) decodes
        // to `.unsupported` so an old build does not blow up on new payloads.
        capabilityTier = (try? c.decode(SceneCapabilityTier.self, forKey: .capabilityTier)) ?? .unsupported
        dependencyWorkshopIDs = (try? c.decodeIfPresent([String].self, forKey: .dependencyWorkshopIDs)) ?? []
    }
}

/// Phase 2.0 capability gate. Computed by the import service after parsing
/// `scene.json`; persisted so the runtime can short-circuit obviously
/// degraded scenes without re-walking the JSON.
enum SceneCapabilityTier: String, Codable, Equatable, Sendable {
    /// All declared objects render via the image-only pipeline.
    case imageOnly
    /// Some objects are renderable but at least one is missing assets or
    /// uses unsupported features. Runtime still mounts an SKScene.
    case degraded
    /// No object can render — UI must fall back to the placeholder card.
    case unsupported

    var localizedLabel: String {
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
