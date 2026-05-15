import Foundation

enum WPEBuiltinShaderName {
    static func normalized(_ shaderName: String, genericImageAsCopy: Bool = false) -> String {
        let stripped = canonicalName(shaderName)

        switch stripped {
        case "solidcolor":
            return "solidcolor"
        case "solidlayer", "util/solidlayer", "models/util/solidlayer":
            return "solidlayer"
        case "copy", "commands/copy", "util/copy":
            return "copy"
        case "compose", "util/compose":
            return "compose"
        case "genericparticle", "particle/genericparticle":
            // Phase 2D-D: native MSL fast path. Leaves combo handling on the
            // table — the no-combo case (which is what most scenes ship)
            // is fully covered by `wpe_genericparticle_fragment`.
            return "genericparticle"
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
            // Phase 2D-E: simple effects whose semantics we model natively.
            // Multi-pass effects (gaussian blur variants, lightshafts) are
            // intentionally NOT aliased here — they need real translation.
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
            // Phase 2D-D: native MSL fast path for the genericimage family.
            // `genericimage1`/`genericimage2`/`genericimage3` route through
            // the single-texture variant; `genericimage4` adds an alpha
            // mask slot. Combos beyond the default no-combo case still
            // need the full GLSL translator — but this lights up the
            // overwhelming majority of corpus scenes that just sample
            // their material texture and apply g_Color/g_Alpha.
            //
            // genericImageAsCopy keeps the legacy executor-fallback
            // behavior available; callers that want the new MSL
            // fast-path must opt out of that flag.
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
        // Phase 2D-G: workshop-relative effect paths point at the same
        // shader by a different prefix (e.g. `workshop/2718465779/effects/
        // pulse`). Treat any path that ends in `/effects/<family>` as an
        // alias so the dispatcher uses the built-in. Trailing punctuation
        // ("pulse_", "Simple_Audio_Bars" with underscore variants) does
        // not match — those are intentional shader divergences and need
        // the translator.
        if shaderName.hasSuffix("/effects/\(family)") {
            return true
        }
        if shaderName.hasSuffix("/effects/\(family)/\(family)") {
            return true
        }
        return false
    }
}
