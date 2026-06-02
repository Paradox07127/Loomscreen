#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

enum WPEMSDFFontMaterial {
    struct Material {
        let uniforms: [String: WPESceneShaderConstantValue]
        let combos: [String: Int]
    }

    static func make(object: WPESceneTextObject, parameters: WPEMSDFParameters) -> Material {
        let outlineEnabled = object.outlineSize > 0
        let blurEnabled = object.blurSize > 0
        let shadowEnabled = object.shadowSize > 0 || object.shadowOffset.x != 0 || object.shadowOffset.y != 0
        let uniforms: [String: WPESceneShaderConstantValue] = [
            "g_Color4": .vector([
                clamped(object.color.x),
                clamped(object.color.y),
                clamped(object.color.z),
                clamped(object.alpha)
            ]),
            "g_RenderVar0": .vector([
                max(parameters.pixelRange, 0.001),
                max(object.outlineSize, 0),
                max(object.blurSize, 0),
                max(object.shadowSize, 0)
            ]),
            "g_RenderVar1": .vector([
                clamped(object.outlineColor.x),
                clamped(object.outlineColor.y),
                clamped(object.outlineColor.z),
                object.shadowOffset.x
            ]),
            "g_RenderVar2": .vector([
                clamped(object.shadowColor.x),
                clamped(object.shadowColor.y),
                clamped(object.shadowColor.z),
                object.shadowOffset.y
            ]),
            "g_RenderVar3": .vector([shadowEnabled ? 1 : 0, 0, 0, 0]),
            "g_HDRParams": .vector([1, 0.5, 0, 0])
        ]
        return Material(
            uniforms: uniforms,
            combos: [
                "MSDF": 1,
                "OUTLINE_ENABLED": outlineEnabled ? 1 : 0,
                "BLUR_ENABLED": blurEnabled ? 1 : 0,
                "DROP_SHADOW_ENABLED": shadowEnabled ? 1 : 0,
                "COLORFONT": 0
            ]
        )
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
#endif
