#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

/// Data-driven dispatch for supported builtin `effect_*` shaders.
///
/// Everything identical across the family — pipeline lookup, blend/pixel-format
/// passthrough, and object-quad vertex-uniform plumbing — lives once in
/// `WPEMetalShaderDispatcher.dispatchEffect`. Everything that genuinely differs
/// per effect — fragment function, whether the object-quad path applies, and how
/// to resolve textures + build the uniform bytes — is one table entry here.
///
/// The uniform layout stays code, not data: each `bind` closure constructs the
/// concrete hand-authored Swift struct (`WPEPulseUniforms`, …) whose field order
/// mirrors `WPEMetalBuiltins.metal`, so `MemoryLayout<U>.stride` is still a
/// compiler guarantee — no generic byte packing, no type-erasure alignment risk.
struct WPEEffectDispatchDescriptor: Sendable {
    /// Resolves and binds this effect's fragment textures + uniform bytes
    /// (buffer 0) onto `encoder`, returning the primary (slot-0) texture the
    /// shared driver feeds to the object-quad placement math.
    /// `@Sendable` (capture-free in practice) so the static table is
    /// concurrency-safe for the per-display render threads on the roadmap.
    typealias Bind = @Sendable (
        _ executor: WPEMetalRenderExecutor,
        _ pass: WPEPreparedRenderPass,
        _ textures: [String: MTLTexture],
        _ frameState: WPEMetalFrameState,
        _ destination: (id: WPEMetalTargetID, texture: MTLTexture),
        _ encoder: MTLRenderCommandEncoder
    ) throws -> MTLTexture

    let kind: WPEBuiltinShaderKind
    /// Spelled out literally — NOT derived from `kind.rawValue` — so an
    /// irregular future name fails the snapshot test loudly instead of
    /// silently mis-deriving at runtime.
    let fragmentName: String
    /// Color-balance, blur, vignette, and water effects intentionally bypass the
    /// object quad; changing this is pixel-visible under parallax and perspective.
    let supportsObjectQuad: Bool
    /// waterwaves' legacy dispatch omitted `cameraParallax` from BOTH
    /// `usesObjectQuadGeometry` and `objectQuadUniforms` (defaulting them to
    /// `.neutral`), unlike every other quad-capable effect. Preserved as data.
    let appliesCameraParallax: Bool
    let bind: Bind

    init(
        kind: WPEBuiltinShaderKind,
        fragmentName: String,
        supportsObjectQuad: Bool,
        appliesCameraParallax: Bool = true,
        bind: @escaping Bind
    ) {
        self.kind = kind
        self.fragmentName = fragmentName
        self.supportsObjectQuad = supportsObjectQuad
        self.appliesCameraParallax = appliesCameraParallax
        self.bind = bind
    }

    /// Shared bind for effects that sample exactly one texture (the
    /// `textureBindings[0] ?? textures[0] ?? source` chain) and fill one
    /// uniform struct from the pass (+ optionally the resolved texture,
    /// e.g. blur's texel size).
    static func singleTexture<U: BitwiseCopyable>(
        _ uniforms: @escaping @Sendable (WPEPreparedRenderPass, MTLTexture) -> U
    ) -> Bind {
        { _, pass, textures, frameState, destination, encoder in
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var value = uniforms(pass, texture)
            encoder.setFragmentBytes(&value, length: MemoryLayout<U>.stride, index: 0)
            return texture
        }
    }

    /// effect_waterflow's legacy `u_Direction` lookup is NOT the standard
    /// `floatScalar(named:)` chain: only the exact-case `u_Direction` key is
    /// consulted (runtime `uniformValues` → authored `constants`), with no
    /// lowercase-key fallback. Preserved verbatim (B2 pixel invariant);
    /// pinned by `WPEMetalShaderDispatcherTests`.
    static func waterFlowDirection(for pass: WPEPreparedRenderPass) -> SIMD2<Float> {
        let dirVec = pass.uniformValues["u_Direction"]?.vectorValue
            ?? pass.pass.constants["u_Direction"]?.vectorValue
            ?? [0, 0.1]
        return SIMD2<Float>(Float(dirVec.first ?? 0), Float(dirVec.dropFirst().first ?? 0.1))
    }

    /// effect_scroll's legacy `u_Speed` lookup is NOT the standard
    /// `floatScalar(named:)` chain: runtime `uniformValues["u_Speed"]` →
    /// authored `constants["u_Speed"]` → authored `constants["speed"]` — the
    /// lowercase key is consulted in `constants` ONLY, never in
    /// `uniformValues`. Preserved verbatim (B2 pixel invariant); pinned by
    /// `WPEMetalShaderDispatcherTests`.
    static func scrollSpeed(for pass: WPEPreparedRenderPass) -> SIMD2<Float> {
        let speedVec = pass.uniformValues["u_Speed"]?.vectorValue
            ?? pass.pass.constants["u_Speed"]?.vectorValue
            ?? pass.pass.constants["speed"]?.vectorValue
            ?? [0.1, 0]
        return SIMD2<Float>(Float(speedVec.first ?? 0.1), Float(speedVec.dropFirst().first ?? 0))
    }

    /// Slot-1 opacity-mask reference chain shared by effect_opacity and
    /// effect_waterwaves: `textureBindings[1] ?? textures[1] ?? binds[1]` —
    /// note `binds` comes LAST here, unlike the custom-shader slot chain where
    /// binds precede textures. `nil` ⇒ the source texture is rebound at slot 1
    /// with the has-mask uniform cleared. Preserved verbatim (B2 pixel
    /// invariant); pinned by `WPEMetalShaderDispatcherTests`.
    static func opacityMaskReference(for pass: WPEPreparedRenderPass) -> WPETextureReference? {
        pass.textureBindings[1] ?? pass.pass.textures[1] ?? pass.pass.binds[1]
    }

    /// effect_color_grading's legacy uniform lookup reads ONLY the runtime
    /// `uniformValues` — authored `constants` are never consulted, a known gap
    /// vs the standard "uniformValues ?? constants" priority chain elsewhere.
    /// Preserved verbatim (B2 pixel invariant — do NOT "fix" in a port);
    /// pinned by `WPEMetalShaderDispatcherTests`.
    static func colorGradingUniforms(for pass: WPEPreparedRenderPass) -> WPEColorGradingUniforms {
        func vec4(_ source: [Double]?, fallback: SIMD4<Float>) -> SIMD4<Float> {
            guard let s = source else { return fallback }
            return SIMD4<Float>(
                Float(s.indices.contains(0) ? s[0] : Double(fallback.x)),
                Float(s.indices.contains(1) ? s[1] : Double(fallback.y)),
                Float(s.indices.contains(2) ? s[2] : Double(fallback.z)),
                Float(s.indices.contains(3) ? s[3] : Double(fallback.w))
            )
        }
        return WPEColorGradingUniforms(
            lift: vec4(pass.uniformValues["u_Lift"]?.vectorValue, fallback: SIMD4<Float>(0, 0, 0, 0)),
            gamma: vec4(pass.uniformValues["u_Gamma"]?.vectorValue, fallback: SIMD4<Float>(1, 1, 1, 1)),
            gain: vec4(pass.uniformValues["u_Gain"]?.vectorValue, fallback: SIMD4<Float>(1, 1, 1, 1))
        )
    }

    /// One entry per builtin `effect_*` kind; snapshot tests pin literals and key coverage.
    static let table: [WPEBuiltinShaderKind: WPEEffectDispatchDescriptor] = {
        let entries: [WPEEffectDispatchDescriptor] = [
            WPEEffectDispatchDescriptor(
                kind: .effectColorBalance,
                fragmentName: "wpe_effect_colorbalance_fragment",
                supportsObjectQuad: false,
                bind: singleTexture { pass, _ in
                    WPEColorBalanceUniforms(
                        brightness: WPEMetalShaderInputs.floatScalar(
                            named: ["u_Brightness", "brightness", "g_BrightnessOffset"],
                            in: pass,
                            default: 0
                        ),
                        contrast: WPEMetalShaderInputs.floatScalar(
                            named: ["u_Contrast", "contrast"],
                            in: pass,
                            default: 1
                        ),
                        saturation: WPEMetalShaderInputs.floatScalar(
                            named: ["u_Saturation", "saturation"],
                            in: pass,
                            default: 1
                        )
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectBlur,
                fragmentName: "wpe_effect_blur_fragment",
                supportsObjectQuad: false,
                bind: singleTexture { pass, texture in
                    WPEBlurUniforms(
                        texelSize: SIMD2<Float>(
                            1 / Float(max(texture.width, 1)),
                            1 / Float(max(texture.height, 1))
                        ),
                        radius: WPEMetalShaderInputs.floatScalar(
                            named: ["u_Radius", "radius", "amount", "strength"],
                            in: pass,
                            default: 1
                        )
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectWater,
                fragmentName: "wpe_effect_water_fragment",
                supportsObjectQuad: false,
                bind: singleTexture { pass, _ in
                    WPEWaterUniforms(
                        amplitude: WPEMetalShaderInputs.floatScalar(
                            named: ["u_Amplitude", "amplitude", "amount", "strength"],
                            in: pass,
                            default: 0.01
                        ),
                        frequency: WPEMetalShaderInputs.floatScalar(
                            named: ["u_Frequency", "frequency", "scale"],
                            in: pass,
                            default: 20
                        ),
                        speed: WPEMetalShaderInputs.floatScalar(
                            named: ["u_Speed", "speed"],
                            in: pass,
                            default: 1
                        ),
                        time: WPEMetalShaderInputs.floatScalar(
                            named: "g_Time",
                            in: pass,
                            default: 0
                        )
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectPulse,
                fragmentName: "wpe_effect_pulse_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    WPEPulseUniforms(
                        frequency: WPEMetalShaderInputs.floatScalar(named: ["g_PulseSpeed", "u_Frequency", "frequency", "speed"], in: pass, default: 1),
                        amplitude: WPEMetalShaderInputs.floatScalar(named: ["g_PulseAmount", "u_Amplitude", "amplitude", "amount", "strength"], in: pass, default: 0.25),
                        time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectIris,
                fragmentName: "wpe_effect_iris_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    WPEIrisUniforms(
                        radius: WPEMetalShaderInputs.floatScalar(named: ["u_Radius", "radius", "size"], in: pass, default: 0.6),
                        softness: WPEMetalShaderInputs.floatScalar(named: ["u_Softness", "softness", "feather"], in: pass, default: 0.1)
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectSpin,
                fragmentName: "wpe_effect_spin_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    WPESpinUniforms(
                        angularSpeed: WPEMetalShaderInputs.floatScalar(named: ["u_AngularSpeed", "u_Speed", "speed", "angularSpeed"], in: pass, default: 0.5),
                        time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectTint,
                fragmentName: "wpe_effect_tint_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    WPETintUniforms(
                        color: WPEMetalShaderInputs.colorVector(for: pass),
                        intensity: WPEMetalShaderInputs.floatScalar(named: ["u_Intensity", "intensity", "amount", "strength"], in: pass, default: 1)
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectFoliageSway,
                fragmentName: "wpe_effect_foliagesway_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    WPEFoliageSwayUniforms(
                        amplitude: WPEMetalShaderInputs.floatScalar(named: ["u_Amplitude", "amplitude", "amount", "strength"], in: pass, default: 0.02),
                        frequency: WPEMetalShaderInputs.floatScalar(named: ["u_Frequency", "frequency", "scale"], in: pass, default: 4),
                        speed: WPEMetalShaderInputs.floatScalar(named: ["u_Speed", "speed"], in: pass, default: 1.5),
                        time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectWaterRipple,
                fragmentName: "wpe_effect_waterripple_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    WPEWaterRippleUniforms(
                        amplitude: WPEMetalShaderInputs.floatScalar(named: ["u_Amplitude", "amplitude", "amount", "strength"], in: pass, default: 0.005),
                        frequency: WPEMetalShaderInputs.floatScalar(named: ["u_Frequency", "frequency", "scale"], in: pass, default: 60),
                        speed: WPEMetalShaderInputs.floatScalar(named: ["u_Speed", "speed"], in: pass, default: 1.0),
                        time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectBlend,
                fragmentName: "wpe_effect_blend_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    WPEBlendUniforms(
                        color: WPEMetalShaderInputs.colorVector(for: pass),
                        opacity: WPEMetalShaderInputs.floatScalar(named: ["u_Opacity", "opacity", "amount", "strength"], in: pass, default: 1)
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectColorGrading,
                fragmentName: "wpe_effect_color_grading_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    colorGradingUniforms(for: pass)
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectWaterWaves,
                fragmentName: "wpe_effect_waterwaves_fragment",
                supportsObjectQuad: true,
                // Legacy waterwaves omitted cameraParallax from the quad path
                // entirely — see the descriptor field doc. Do not "fix" here.
                appliesCameraParallax: false,
                bind: { executor, pass, textures, frameState, destination, encoder in
                    let sourceReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
                    let sourceTexture = try WPEMetalShaderInputs.resolve(
                        reference: sourceReference,
                        textures: textures,
                        frameState: frameState,
                        currentTargetID: destination.id
                    )
                    let maskReference = opacityMaskReference(for: pass)
                    let maskTexture: MTLTexture
                    let hasMask: Float
                    if let maskReference {
                        maskTexture = try WPEMetalShaderInputs.resolve(
                            reference: maskReference,
                            textures: textures,
                            frameState: frameState,
                            currentTargetID: destination.id
                        )
                        hasMask = 1
                    } else {
                        maskTexture = sourceTexture
                        hasMask = 0
                    }
                    encoder.setFragmentTexture(sourceTexture, index: 0)
                    encoder.setFragmentTexture(maskTexture, index: 1)

                    // WPE's waterwaves.vert sets v_Direction = rotate((0,1), g_Direction[rad]).
                    let waveAngle = WPEMetalShaderInputs.floatScalar(named: ["g_Direction", "direction"], in: pass, default: 0)
                    let speed = WPEMetalShaderInputs.floatScalar(named: ["g_Speed", "speed"], in: pass, default: 5)
                    let scale = WPEMetalShaderInputs.floatScalar(named: ["g_Scale", "scale"], in: pass, default: 200)
                    let strength = WPEMetalShaderInputs.floatScalar(named: ["g_Strength", "strength"], in: pass, default: 0.1)

                    if !executor.loggedWaterWavesDispatch {
                        executor.loggedWaterWavesDispatch = true
                        Logger.info(
                            "WPE waterwaves dispatch ran (builtin effect_waterwaves): hasMask=\(hasMask) mask=\(maskTexture.width)x\(maskTexture.height) dest=\(destination.texture.width)x\(destination.texture.height) speed=\(speed) scale=\(scale) strength=\(strength)",
                            category: .wpeRender
                        )
                    }

                    let maskResolution = WPEMetalTextureMetadataRegistry.shared.resolution(for: maskTexture)
                    var uniforms = WPEWaterWavesUniforms(
                        time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0),
                        speed: speed,
                        scale: scale,
                        strength: strength,
                        exponent: WPEMetalShaderInputs.floatScalar(named: ["g_Exponent", "exponent"], in: pass, default: 1),
                        directionX: -sin(waveAngle),
                        directionY: cos(waveAngle),
                        hasMask: hasMask,
                        texture1Resolution: SIMD4<Float>(
                            Float(maskResolution.textureWidth),
                            Float(maskResolution.textureHeight),
                            Float(maskResolution.imageWidth),
                            Float(maskResolution.imageHeight)
                        )
                    )
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEWaterWavesUniforms>.stride, index: 0)
                    return sourceTexture
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectOpacity,
                fragmentName: "wpe_effect_opacity_fragment",
                supportsObjectQuad: true,
                bind: { _, pass, textures, frameState, destination, encoder in
                    let sourceReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
                    let sourceTexture = try WPEMetalShaderInputs.resolve(
                        reference: sourceReference,
                        textures: textures,
                        frameState: frameState,
                        currentTargetID: destination.id
                    )
                    let maskReference = opacityMaskReference(for: pass)
                    let maskTexture: MTLTexture
                    let hasMask: Float
                    if let maskReference {
                        maskTexture = try WPEMetalShaderInputs.resolve(
                            reference: maskReference,
                            textures: textures,
                            frameState: frameState,
                            currentTargetID: destination.id
                        )
                        hasMask = 1
                    } else {
                        maskTexture = sourceTexture
                        hasMask = 0
                    }
                    encoder.setFragmentTexture(sourceTexture, index: 0)
                    encoder.setFragmentTexture(maskTexture, index: 1)
                    var uniforms = WPEOpacityUniforms(
                        opacity: WPEMetalShaderInputs.floatScalar(
                            named: ["u_Opacity", "opacity", "amount", "alpha", "g_UserAlpha"],
                            in: pass,
                            default: 1
                        ),
                        hasMask: hasMask,
                        maskScaleX: Float(destination.texture.width) / Float(max(maskTexture.width, 1)),
                        maskScaleY: Float(destination.texture.height) / Float(max(maskTexture.height, 1))
                    )
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEOpacityUniforms>.stride, index: 0)
                    return sourceTexture
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectScroll,
                fragmentName: "wpe_effect_scroll_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    WPEScrollUniforms(
                        speed: scrollSpeed(for: pass),
                        time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectWaterFlow,
                fragmentName: "wpe_effect_waterflow_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    WPEWaterFlowUniforms(
                        direction: waterFlowDirection(for: pass),
                        speed: WPEMetalShaderInputs.floatScalar(named: ["u_Speed", "speed"], in: pass, default: 1),
                        time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectVignette,
                fragmentName: "wpe_effect_vignette_fragment",
                supportsObjectQuad: false,
                bind: singleTexture { pass, _ in
                    WPEVignetteUniforms(
                        innerRadius: WPEMetalShaderInputs.floatScalar(
                            named: ["u_InnerRadius", "innerRadius", "inner"],
                            in: pass,
                            default: 0.35
                        ),
                        outerRadius: WPEMetalShaderInputs.floatScalar(
                            named: ["u_OuterRadius", "outerRadius", "outer"],
                            in: pass,
                            default: 0.75
                        ),
                        intensity: WPEMetalShaderInputs.floatScalar(
                            named: ["u_Intensity", "intensity", "amount", "strength"],
                            in: pass,
                            default: 0.5
                        )
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectShimmer,
                fragmentName: "wpe_effect_shimmer_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    WPEShimmerUniforms(
                        speed: WPEMetalShaderInputs.floatScalar(named: ["u_Speed", "speed"], in: pass, default: 4),
                        intensity: WPEMetalShaderInputs.floatScalar(named: ["u_Intensity", "intensity", "amount", "strength"], in: pass, default: 0.2),
                        time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                    )
                }
            ),
            WPEEffectDispatchDescriptor(
                kind: .effectShake,
                fragmentName: "wpe_effect_shake_fragment",
                supportsObjectQuad: true,
                bind: singleTexture { pass, _ in
                    WPEShakeUniforms(
                        magnitude: WPEMetalShaderInputs.floatScalar(
                            named: ["u_Magnitude", "magnitude", "amount", "strength"],
                            in: pass,
                            default: 0.01
                        ),
                        time: WPEMetalShaderInputs.floatScalar(
                            named: "g_Time",
                            in: pass,
                            default: 0
                        ),
                        frequency: WPEMetalShaderInputs.floatScalar(
                            named: ["u_Frequency", "frequency", "speed"],
                            in: pass,
                            default: 24
                        )
                    )
                }
            ),
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.kind, $0) })
    }()
}

extension WPEMetalShaderDispatcher {
    /// Shared driver for every table-driven effect case: pipeline selection (with
    /// the object-quad vertex variant), descriptor bind, then the object-quad
    /// vertex uniforms — the exact statement order of the legacy per-case
    /// methods (PSO before texture resolution, so a missing texture still
    /// leaves the pipeline state set: byte-identical failure behavior).
    func dispatchEffect(
        _ descriptor: WPEEffectDispatchDescriptor,
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let cameraParallax = descriptor.appliesCameraParallax ? frameState.cameraParallax : .neutral
        let usesObjectQuad = descriptor.supportsObjectQuad
            && executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: cameraParallax)
        encoder.setRenderPipelineState(try executor.renderPipeline(
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: descriptor.fragmentName,
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        let primary = try descriptor.bind(executor, pass, textures, frameState, destination, encoder)
        guard usesObjectQuad else { return }
        var quadUniforms = executor.objectQuadUniforms(
            for: layer,
            sceneSize: executor.objectQuadSceneSize(
                for: pass,
                layer: layer,
                destination: destination,
                frameState: frameState
            ),
            cameraParallax: cameraParallax,
            sourceTexture: primary,
            cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
        )
        encoder.setVertexBytes(
            &quadUniforms,
            length: MemoryLayout<WPEObjectQuadUniforms>.stride,
            index: 1
        )
    }
}
#endif
