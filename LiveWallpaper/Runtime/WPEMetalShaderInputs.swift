#if !LITE_BUILD
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
    /// WPE scene JSON authors `g_Color` in sRGB perceptual space ("0.5 0.5 0.5" → mid-gray on screen).
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

    /// Resolves a `WPETextureReference` against the live frame state plus the caller-provided textures dictionary.
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
            if let texture = frameState.latestNamedTextures[name] {
                return texture
            }
            if Self.isSceneAliasName(name) {
                // WPE's `_rt_FullFrameBuffer` (and the other scene aliases) means
                // "what is CURRENTLY rendered to the background's output" — never
                // the previous frame. `currentFrameSceneTexture` is non-nil only
                // once a scene-target pass has written this frame; before that we
                // fall back to `output`, which the executor clears to the scene
                // clear color at frame start. Using last frame's content here
                // would create a positive-feedback loop (shine_combine COPYBG +
                // `albedo.a = saturate(albedo.a + rays.a)` ramps the layer white).
                return frameState.currentFrameSceneTexture ?? frameState.output
            }
            if let aliased = resolveAliasedNamedTexture(name: name, frameState: frameState) {
                return aliased
            }
            let availableKeys = Array(frameState.latestNamedTextures.keys).sorted().joined(separator: ", ")
            Logger.warning(
                "WPE Metal: named FBO '\(name)' miss — declared targets: \(availableKeys)",
                category: .screenManager
            )
            WPESceneDebugArtifacts.shared.appendLog(
                "[fbo.miss] '\(name)' — available: \(availableKeys)",
                level: .warning
            )
            throw WPEMetalRenderExecutorError.missingTexture(reference)

        case .previous:
            guard let texture = frameState.latestTexture(for: currentTargetID) else {
                throw WPEMetalRenderExecutorError.missingTexture(reference)
            }
            return texture
        }
    }

    /// Best-effort fuzzy lookup when an `.fbo(name)` reference misses the
    /// exact `latestNamedTextures` key. WPE pass authoring is loose about
    /// `_rt_` prefixes and case; rather than fail the whole scene, try a
    /// short list of common transformations and accept the first hit.
    /// Returns `nil` when no fuzzy candidate matches (caller then logs the
    /// available keys and throws).
    static func resolveAliasedNamedTexture(
        name: String,
        frameState: WPEMetalFrameState
    ) -> MTLTexture? {
        let candidates: [String] = [
            "_rt_" + name,
            name.hasPrefix("_rt_") ? String(name.dropFirst(4)) : nil,
            name.hasPrefix("_") ? String(name.dropFirst()) : nil
        ].compactMap { $0 }
        for candidate in candidates {
            if let texture = frameState.latestNamedTextures[candidate] {
                return texture
            }
        }
        let lowercased = name.lowercased()
        for (key, texture) in frameState.latestNamedTextures
        where key != name && key.lowercased() == lowercased {
            return texture
        }
        return nil
    }

    /// True for `_rt_*` names that WPE's runtime aliases to the live scene texture rather than a discrete FBO allocation.
    static func isSceneAliasName(_ name: String) -> Bool {
        switch name {
        case "_rt_FullFrameBuffer",
             "_rt_HalfFrameBuffer",
             "_rt_QuarterFrameBuffer",
             "_rt_imageLayerComposite":
            return true
        default:
            return name.hasPrefix("_rt_EightBuffer")
                || name.hasPrefix("_rt_Mip")
                || name.hasPrefix("_rt_downscaled")
        }
    }

    /// Maps the WPE shader name onto one of the executor's built-in fragment functions.
    static func normalizedBuiltinShaderName(_ shaderName: String) -> String {
        WPEBuiltinShaderName.normalized(shaderName, genericImageAsCopy: false)
    }

    /// Phase 2D-C: scalar-uniform lookup that walks `pass.uniformValues` first (runtime-merged values from Phase 2B) then `pass.pass.constants` (authored material defaults).
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
        // Parallax is applied as a geometry translation in `objectQuadUniforms`
        // (scene-targeted passes only), gated by the scene's camera-parallax
        // settings. The legacy raw-pointer UV shift here is intentionally
        // removed so it can't double-shift non-identity copy passes or move
        // layers when camera parallax is disabled.
        WPECopyUniforms(uvOffset: SIMD2<Float>(0, 0))
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
        case .animated(let value):
            return value.scalar(at: 0).map(Float.init)
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
#endif
