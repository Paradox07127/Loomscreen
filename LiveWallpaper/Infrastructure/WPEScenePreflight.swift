import Foundation

/// Pre-render capability gate for a single scene project. Reads the parsed
/// `WPESceneDocument` plus project metadata (Windows plugin presence,
/// whether the package contains custom shader sources) and returns the
/// tier the runtime should expect, plus the precise feature flags the
/// scene declared.
///
/// Truth-telling: the tier reflects what the SCENE asks for, not what the
/// renderer currently supports. The dispatch layer is what downgrades
/// `nativePlayable` to `degradedPlayable` when (e.g.) the shader compiler
/// hasn't shipped yet — that keeps the contract honest as features land
/// without re-classifying every scene.
enum WPEScenePreflight {
    static func classify(
        document: WPESceneDocument,
        project: WallpaperEngineProject,
        scenePackageEntries: [String]
    ) -> WPEScenePreflightResult {
        var flags = Set<WPESceneFeatureFlag>()

        if project.requiresWindowsPlugin {
            flags.insert(.windowsPlugin)
        }
        if scenePackageEntries.contains(where: { entry in
            let lowered = entry.lowercased()
            return lowered.hasSuffix(".vert") || lowered.hasSuffix(".frag")
        }) {
            flags.insert(.customShaderSource)
        }

        for diagnostic in document.diagnostics {
            // The parser already emits info-level diagnostics for
            // unsupported object kinds and animation layers — mine those
            // strings rather than re-walking the JSON. (Parser owns the
            // source of truth for what it could and couldn't model.)
            let lowered = diagnostic.message.lowercased()
            if lowered.contains("particle") && lowered.contains("unsupported") {
                flags.insert(.particleObject)
            } else if lowered.contains("text") && lowered.contains("unsupported") {
                flags.insert(.textObject)
            } else if lowered.contains("sound") && lowered.contains("unsupported") {
                flags.insert(.soundObject)
            } else if lowered.contains("light") && lowered.contains("unsupported") {
                flags.insert(.lightObject)
            } else if lowered.contains("animationlayers") {
                flags.insert(.animationLayer)
            }
        }

        for object in document.imageObjects {
            if !object.effects.isEmpty { flags.insert(.imageEffect) }
            if !object.animationLayers.isEmpty { flags.insert(.animationLayer) }
        }

        let tier = Self.tier(for: flags, hasImageObjects: !document.imageObjects.isEmpty)
        return WPEScenePreflightResult(tier: tier, featureFlags: flags)
    }

    private static func tier(
        for flags: Set<WPESceneFeatureFlag>,
        hasImageObjects: Bool
    ) -> WPEScenePreflightTier {
        if flags.contains(.windowsPlugin) { return .unsupported }
        if !hasImageObjects && flags.isDisjoint(with: [.particleObject, .textObject, .lightObject]) {
            return .unsupported
        }

        // Order matters: the most expensive missing capability dominates.
        if flags.contains(.particleObject)
            || flags.contains(.textObject)
            || flags.contains(.soundObject)
            || flags.contains(.lightObject)
            || flags.contains(.animationLayer) {
            return .runtimeSystemsRequired
        }
        if flags.contains(.customShaderSource) {
            return .shaderTranslationRequired
        }
        if flags.contains(.imageEffect) {
            // Effects pipeline is partially supported by the built-in
            // shaders; treat as degraded so the UI surfaces the caveat.
            return .degradedPlayable
        }
        return .nativePlayable
    }
}

struct WPEScenePreflightResult: Equatable, Sendable {
    let tier: WPEScenePreflightTier
    let featureFlags: Set<WPESceneFeatureFlag>
}

enum WPEScenePreflightTier: String, Codable, Equatable, Sendable {
    /// Scene uses only built-in shaders + image objects with no exotic
    /// runtime systems. The current renderer can play this 1:1 today.
    case nativePlayable
    /// Renderable, but at least one declared feature is approximated
    /// (e.g. an effect lands on a built-in fragment shader that doesn't
    /// exactly match the WPE original).
    case degradedPlayable
    /// Scene declares custom GLSL — needs the WPE→MSL translator to play.
    case shaderTranslationRequired
    /// Scene needs a runtime subsystem that's not implemented yet
    /// (particle, text, sound, light, animation layer / puppet warp).
    case runtimeSystemsRequired
    /// Scene cannot run on macOS for hard reasons (Windows plugin, no
    /// renderable objects).
    case unsupported

    var localizedLabel: String {
        switch self {
        case .nativePlayable:
            return String(localized: "Native", defaultValue: "Native", comment: "Scene preflight tier label.")
        case .degradedPlayable:
            return String(localized: "Approximate", defaultValue: "Approximate", comment: "Scene preflight tier label.")
        case .shaderTranslationRequired:
            return String(localized: "Needs shader translation", defaultValue: "Needs shader translation", comment: "Scene preflight tier label.")
        case .runtimeSystemsRequired:
            return String(localized: "Needs runtime systems", defaultValue: "Needs runtime systems", comment: "Scene preflight tier label.")
        case .unsupported:
            return String(localized: "Unsupported", defaultValue: "Unsupported", comment: "Scene preflight tier label.")
        }
    }
}
