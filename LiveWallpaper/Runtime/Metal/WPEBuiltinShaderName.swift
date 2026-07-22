#if !LITE_BUILD
import Foundation
import os

enum WPEBuiltinShaderName {
    /// `compute` walks a ~20-branch effect cascade allocating dozens of throwaway
    /// interpolated strings per call, on the per-pass dispatch path every frame
    /// (trace: `isEffectAlias` + `DefaultStringInterpolation` ≈ 5% of one core).
    /// The result is invariant for a shader name → memoize. Keyed on the raw input
    /// so hits skip even the lowercase/path canonicalization (equivalent spellings
    /// may take separate entries — never a wrong collision). Lock-guarded for the
    /// per-display render threads on the roadmap; capped against unbounded scenes.
    private static let normalizedCache = OSAllocatedUnfairLock(initialState: [String: String]())
    private static let normalizedCacheLimit = 512

    static func normalized(_ shaderName: String, genericImageAsCopy: Bool = false) -> String {
        guard !genericImageAsCopy else {
            return compute(shaderName, genericImageAsCopy: true)
        }
        return normalizedCache.withLock { cache in
            if let cached = cache[shaderName] { return cached }
            let result = compute(shaderName, genericImageAsCopy: false)
            if cache.count >= normalizedCacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[shaderName] = result
            return result
        }
    }

    private static func compute(_ shaderName: String, genericImageAsCopy: Bool) -> String {
        let stripped = canonicalName(shaderName)

        switch stripped {
        case "solidcolor":
            return "solidcolor"
        case "solidlayer", "util/solidlayer", "models/util/solidlayer":
            return "solidlayer"
        case "copy", "commands/copy", "util/copy":
            return "copy"
        case "wpe_blend_composite":
            return "wpe_blend_composite"
        case "compose", "util/compose", "composelayer", "util/composelayer":
            return "compose"
        case "genericparticle", "particle/genericparticle":
            return "genericparticle"
        case "generic4":
            return "genericimage4"
        default:
            if isEffectAlias(stripped, family: "colorbalance") {
                return "effect_colorbalance"
            }
            if isEffectAlias(stripped, family: "blur") {
                return "effect_blur"
            }
            if isEffectAlias(stripped, family: "vignette") {
                return "effect_vignette"
            }
            if isEffectAlias(stripped, family: "water")
                || isEffectAlias(stripped, family: "distort") {
                return "effect_water"
            }
            if isEffectAlias(stripped, family: "shake") {
                return "effect_shake"
            }
            if isEffectAlias(stripped, family: "opacity") {
                return "effect_opacity"
            }
            if isEffectAlias(stripped, family: "scroll") {
                return "effect_scroll"
            }
            if isEffectAlias(stripped, family: "pulse") {
                return "effect_pulse"
            }
            if isEffectAlias(stripped, family: "iris") {
                return "effect_iris"
            }
            if isEffectAlias(stripped, family: "waterwaves") {
                return "effect_waterwaves"
            }
            if isEffectAlias(stripped, family: "spin") {
                return "effect_spin"
            }
            if isEffectAlias(stripped, family: "tint") {
                return "effect_tint"
            }
            if isEffectAlias(stripped, family: "foliagesway") {
                return "effect_foliagesway"
            }
            if isEffectAlias(stripped, family: "waterripple") {
                return "effect_waterripple"
            }
            if isEffectAlias(stripped, family: "blend") {
                return "effect_blend"
            }
            if isEffectAlias(stripped, family: "waterflow") {
                return "effect_waterflow"
            }
            if isEffectAlias(stripped, family: "color_grading") || isEffectAlias(stripped, family: "colorgrading") {
                return "effect_color_grading"
            }
            if isEffectAlias(stripped, family: "shimmer") {
                return "effect_shimmer"
            }
            if isGenericImageCanonicalName(stripped) {
                if genericImageAsCopy {
                    return "copy"
                }
                if stripped == "genericimage4" || stripped == "genericimage5" {
                    return "genericimage4"
                }
                return "genericimage2"
            }
            return stripped
        }
    }

    static func isGenericImageShader(_ shaderName: String) -> Bool {
        isGenericImageCanonicalName(canonicalName(shaderName))
    }

    private static func canonicalName(_ shaderName: String) -> String {
        let lower = shaderName.lowercased()
        let withoutJSON = lower.hasSuffix(".json") ? String(lower.dropLast(5)) : lower
        return withoutJSON.hasPrefix("materials/")
            ? String(withoutJSON.dropFirst("materials/".count))
            : withoutJSON
    }

    private static func isGenericImageCanonicalName(_ shaderName: String) -> Bool {
        guard shaderName.hasPrefix("genericimage") else {
            return false
        }
        let suffix = shaderName.dropFirst("genericimage".count)
        return suffix.allSatisfy(\.isNumber)
    }

    private static func isEffectAlias(_ shaderName: String, family: String) -> Bool {
        if shaderName == family
            || shaderName == "effects/\(family)"
            || shaderName == "effects/\(family)/\(family)" {
            return true
        }
        if shaderName.hasSuffix("/effects/\(family)") {
            return true
        }
        if shaderName.hasSuffix("/effects/\(family)/\(family)") {
            return true
        }
        return false
    }
}

/// Typed identity for the builtin shader names `dispatch` matches by exact
/// string equality (typed identity + decomposition, strictly
/// behavior-preserving). Raw values are fixed-point outputs of
/// `WPEBuiltinShaderName.normalized`; case order mirrors the legacy switch.
/// Names matched by pattern rather than exact equality stay string checks on
/// the custom/transpiled fallback path: `godrays_combine` (equality-or-suffix
/// match in `dispatchCustomShader`), the wave/flutter substring check
/// (diagnostics only), and the raw `commands/copy` spelling probed inside the
/// copy case body. `WPEMetalShaderDispatcherTests` pins the exact raw-value
/// set. Lives here (Infrastructure, beside its normalizer fixed-point source)
/// so the graph/pipeline builders' judgment sites don't add Infra→Runtime
/// coupling.
enum WPEBuiltinShaderKind: String, CaseIterable {
    case solidColor = "solidcolor"
    case solidLayer = "solidlayer"
    case copy = "copy"
    case compose = "compose"
    case effectColorBalance = "effect_colorbalance"
    case effectBlur = "effect_blur"
    case effectVignette = "effect_vignette"
    case effectWater = "effect_water"
    case genericImage2 = "genericimage2"
    case genericImage4 = "genericimage4"
    case effectOpacity = "effect_opacity"
    case effectScroll = "effect_scroll"
    case effectPulse = "effect_pulse"
    case effectIris = "effect_iris"
    case effectWaterWaves = "effect_waterwaves"
    case effectSpin = "effect_spin"
    case effectTint = "effect_tint"
    case effectFoliageSway = "effect_foliagesway"
    case effectWaterRipple = "effect_waterripple"
    case effectBlend = "effect_blend"
    case effectWaterFlow = "effect_waterflow"
    case effectColorGrading = "effect_color_grading"
    case effectShimmer = "effect_shimmer"
    case genericParticle = "genericparticle"
    case effectShake = "effect_shake"
    /// Synthesized by the render-graph builder (never authored in a scene) for
    /// layers whose WPE blend mode reads the destination.
    case blendComposite = "wpe_blend_composite"
}

extension WPEBuiltinShaderKind {
    /// The judgment-site form shared by dispatcher, graph builder, and renderer
    /// preload: normalize an authored shader name once, then match the typed
    /// builtin identity. `nil` = open-set custom (workshop) shader. Uses the
    /// identity-preserving normalizer variant (`genericImageAsCopy: false`) —
    /// the same one every judgment site already used. Never write
    /// the normalized string back into `WPERenderPass.shader`: custom shaders'
    /// disk paths, cache keys, and diagnostics all need the authored string.
    init?(normalizing shaderName: String) {
        self.init(rawValue: WPEBuiltinShaderName.normalized(shaderName))
    }
}
#endif
