#if !LITE_BUILD
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

        // Phase 2D-O: particle/text/sound runtimes have shipped — they
        // no longer auto-bump to `runtimeSystemsRequired`. Only the
        // remaining unimplemented runtime objects (lights) and
        // animation-layer mesh deformation block playback. Scenes
        // declaring animationlayers still render their base image
        // layers; the warp is approximated as a static composite.
        if flags.contains(.lightObject) {
            return .runtimeSystemsRequired
        }
        if flags.contains(.customShaderSource) {
            // Shader translator is shipping — degrade to indicate the
            // visual may differ from the WPE reference, but don't
            // declare the scene unplayable.
            return .degradedPlayable
        }
        if flags.contains(.animationLayer) {
            // Animation layers parse and the base image renders; mesh
            // deformation is approximated as static. Surface as
            // degraded so users know.
            return .degradedPlayable
        }
        if flags.contains(.imageEffect) {
            return .degradedPlayable
        }
        return .nativePlayable
    }
}

struct WPEScenePreflightResult: Equatable, Sendable {
    let tier: WPEScenePreflightTier
    let featureFlags: Set<WPESceneFeatureFlag>
}

// WPEScenePreflightTier was moved to LiveWallpaperCore/Schema/WPEScenePreflightTier.swift.
#endif
