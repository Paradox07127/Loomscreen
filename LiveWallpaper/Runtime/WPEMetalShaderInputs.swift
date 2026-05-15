import Foundation
import Metal
import simd

/// Stateless helpers that compute fragment uniforms and resolve texture
/// references for the WPE Metal render pipeline. Carved out of
/// `WPEMetalRenderExecutor` so the executor doesn't have to own pure shader
/// input math, and so `WPEMetalShaderDispatcher` calls these directly
/// without routing through an executor reference. Everything in here is
/// `static` and reads only from its parameters.
enum WPEMetalShaderInputs {
    /// WPE scene JSON authors `g_Color` in sRGB perceptual space ("0.5 0.5
    /// 0.5" → mid-gray on screen). The render target is sRGB-tagged, so
    /// the hardware applies linear→sRGB encode on store; we therefore must
    /// feed the shader linear-space RGB. Alpha stays unchanged — Metal
    /// does not gamma-encode the alpha channel on sRGB targets.
    static func colorVector(for pass: WPEPreparedRenderPass) -> SIMD4<Float> {
        let vector = pass.uniformValues["g_Color"]?.vectorValue
            ?? pass.pass.constants["g_Color"]?.vectorValue
            ?? [1, 1, 1, 1]
        return SIMD4<Float>(
            sRGBToLinear(Float(vector[safe: 0] ?? 1)),
            sRGBToLinear(Float(vector[safe: 1] ?? 1)),
            sRGBToLinear(Float(vector[safe: 2] ?? 1)),
            Float(vector[safe: 3] ?? 1)
        )
    }

    /// Resolves a `WPETextureReference` against the live frame state plus the
    /// caller-provided textures dictionary. Used by the dispatcher per pass.
    static func resolve(
        reference: WPETextureReference,
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        currentTargetID: WPEMetalTargetID
    ) throws -> MTLTexture {
        switch reference {
        case .image(let path), .asset(let path):
            guard let texture = textures[path] else {
                throw WPEMetalRenderExecutorError.missingTexture(reference)
            }
            return texture

        case .fbo(let name):
            guard let texture = frameState.latestNamedTextures[name] else {
                throw WPEMetalRenderExecutorError.missingTexture(reference)
            }
            return texture

        case .previous:
            guard let texture = frameState.latestTexture(for: currentTargetID) else {
                throw WPEMetalRenderExecutorError.missingTexture(reference)
            }
            return texture
        }
    }

    /// Maps the WPE shader name onto one of the executor's built-in fragment
    /// functions. Phase 2C recognises `solidcolor`, `solidlayer`, `copy`,
    /// `compose`, and `genericimage*`. Phase 2D-C extends the table with the
    /// pre-compiled MSL effect set: `colorbalance`, `blur`, `vignette`,
    /// `water` (alias `distort`), `shake`. Custom shaders still throw
    /// `unsupportedShader` until the full GLSL translator (Phase 2D-A/B)
    /// lands.
    static func normalizedBuiltinShaderName(_ shaderName: String) -> String {
        // Phase 2D-D: drop the legacy genericImageAsCopy fallback so the
        // dispatcher routes genericimage* through the new native MSL
        // built-ins instead of the bare copy shader. Callers that still
        // want the old behavior pass `genericImageAsCopy: true` directly.
        WPEBuiltinShaderName.normalized(shaderName, genericImageAsCopy: false)
    }

    /// Phase 2D-C: scalar-uniform lookup that walks `pass.uniformValues`
    /// first (runtime-merged values from Phase 2B) then `pass.pass.constants`
    /// (authored material defaults). Multiple aliases supported because WPE
    /// shader uniforms ship under several legacy names (`u_X`, `X`,
    /// `g_XOffset`, etc.).
    static func floatScalar(
        named name: String,
        in pass: WPEPreparedRenderPass,
        default defaultValue: Float
    ) -> Float {
        scalarFloat(pass.uniformValues[name])
            ?? scalarFloat(pass.pass.constants[name])
            ?? defaultValue
    }

    static func floatScalar(
        named names: [String],
        in pass: WPEPreparedRenderPass,
        default defaultValue: Float
    ) -> Float {
        for name in names {
            if let value = scalarFloat(pass.uniformValues[name]) {
                return value
            }
        }
        for name in names {
            if let value = scalarFloat(pass.pass.constants[name]) {
                return value
            }
        }
        return defaultValue
    }

    static func copyUniforms(for pass: WPEPreparedRenderPass, layer: WPERenderLayer) -> WPECopyUniforms {
        let vector = pass.uniformValues["g_PointerPosition"]?.vectorValue ?? [0.5, 0.5]
        let pointer = SIMD2<Double>(
            vector[safe: 0] ?? 0.5,
            vector[safe: 1] ?? 0.5
        )
        return WPECopyUniforms(
            uvOffset: parallaxUVOffset(
                pointerPosition: pointer,
                parallaxDepth: layer.parallaxDepth
            )
        )
    }

    static func parallaxUVOffset(
        pointerPosition: SIMD2<Double>,
        parallaxDepth: Double
    ) -> SIMD2<Float> {
        guard parallaxDepth != 0 else {
            return SIMD2<Float>(0, 0)
        }
        let delta = SIMD2<Double>(
            pointerPosition.x - 0.5,
            pointerPosition.y - 0.5
        )
        let offset = delta * parallaxDepth * 0.1
        return SIMD2<Float>(
            Float(min(max(offset.x, -0.05), 0.05)),
            Float(min(max(offset.y, -0.05), 0.05))
        )
    }

    /// Standard sRGB EOTF used by Metal's `_srgb` pixel formats.
    private static func sRGBToLinear(_ value: Float) -> Float {
        let clamped = min(max(value, 0), 1)
        if clamped <= 0.04045 {
            return clamped / 12.92
        }
        return Float(pow(Double((clamped + 0.055) / 1.055), 2.4))
    }

    private static func scalarFloat(_ value: WPESceneShaderConstantValue?) -> Float? {
        switch value {
        case .number(let number):
            return Float(number)
        case .vector(let vector):
            return vector.first.map(Float.init)
        case .bool(let bool):
            return bool ? 1 : 0
        case .string(let string):
            return Float(string)
        case nil:
            return nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
