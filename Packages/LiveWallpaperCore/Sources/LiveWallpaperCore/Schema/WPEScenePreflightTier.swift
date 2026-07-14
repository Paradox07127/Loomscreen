import Foundation

/// Scene preflight verdict — persisted in `SceneDescriptor` so the inspector
/// can render the right badge without re-parsing the scene blob. Stays in
/// Core because the schema must round-trip Lite↔Pro losslessly.
public enum WPEScenePreflightTier: String, Codable, Equatable, Sendable {
    /// Scene uses only built-in shaders + image objects with no exotic
    /// runtime systems. The current renderer can play this 1:1 today.
    case nativePlayable
    /// Renderable, but at least one declared feature is approximated
    /// (e.g. an effect lands on a built-in fragment shader that doesn't
    /// exactly match the WPE original).
    case degradedPlayable
    /// Scene needs a runtime subsystem that's not implemented yet
    /// (particle, text, sound, light, animation layer / puppet warp).
    case runtimeSystemsRequired
    /// Scene cannot run on macOS for hard reasons (Windows plugin, no
    /// renderable objects).
    case unsupported

    public var localizedLabel: String {
        switch self {
        case .nativePlayable:
            return String(localized: "Native", defaultValue: "Native", comment: "Scene preflight tier label.")
        case .degradedPlayable:
            return String(localized: "Approximate", defaultValue: "Approximate", comment: "Scene preflight tier label.")
        case .runtimeSystemsRequired:
            return String(localized: "Needs runtime systems", defaultValue: "Needs runtime systems", comment: "Scene preflight tier label.")
        case .unsupported:
            return String(localized: "Unsupported", defaultValue: "Unsupported", comment: "Scene preflight tier label.")
        }
    }
}

/// Per-scene capability flags declared by the preflight pass — persisted in
/// `SceneDescriptor` so the inspector can list "needs particle / text /
/// sound / light / ..." without re-running the analysis. Pure raw-value
/// enum; the analyzer that produces it lives in ProWPE.
public enum WPESceneFeatureFlag: String, Codable, Hashable, Sendable {
    case customShaderSource
    case particleObject
    case textObject
    case soundObject
    case lightObject
    case animationLayer
    case imageEffect
    case unknownObject
    case windowsPlugin
}
