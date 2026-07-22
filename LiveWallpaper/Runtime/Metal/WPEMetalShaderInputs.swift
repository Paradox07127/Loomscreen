#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import simd

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
            // First-frame read of a declared-but-unwritten local FBO: WPE reads a
            // freshly created RT as all-zero (motionblur pass0 samples its own
            // `_rt_FullCompoBuffer1` history before pass1 writes it). Hand back a
            // cached zero stand-in so `performLoad` prewarm doesn't kill the scene.
            // NOTE: no `registerWrite` here — `frameState` is passed by value, and
            // the pool caches the stand-in, so a same-frame re-miss reuses it and the
            // real self-heal lands when the producing pass writes the target. Only
            // pool-DECLARED names take this path; anything else still throws below.
            if let zero = frameState.renderTargetPool?.zeroFilledPlaceholderTexture(forDeclaredFBO: name) {
                return zero
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

    /// Fuzzy fallback when an `.fbo(name)` misses the exact `latestNamedTextures`
    /// key: WPE pass authoring is loose about `_rt_` prefixes and case, so try a
    /// few common transformations rather than failing the whole scene.
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

    /// True for `_rt_*` names that WPE's runtime aliases to the live scene texture rather
    /// than a discrete FBO allocation. Forwards to the canonical single source of truth in
    /// the Schema package shared with the graph builder.
    static func isSceneAliasName(_ name: String) -> Bool {
        WPETextureReference.isSceneAliasName(name)
    }

    static func normalizedBuiltinShaderName(_ shaderName: String) -> String {
        WPEBuiltinShaderName.normalized(shaderName, genericImageAsCopy: false)
    }

    /// Looks up `pass.uniformValues` (runtime-merged) first, then `pass.pass.constants` (authored defaults).
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
