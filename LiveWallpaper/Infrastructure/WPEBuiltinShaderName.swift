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
            if genericImageAsCopy, isGenericImageCanonicalName(stripped) {
                return "copy"
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
        shaderName == family
            || shaderName == "effects/\(family)"
            || shaderName == "effects/\(family)/\(family)"
    }
}
