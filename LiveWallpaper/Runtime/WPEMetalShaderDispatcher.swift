import Foundation
import Metal

/// Dispatches a prepared pass onto the right Metal pipeline state and
/// fragment uniforms. Extracted so the dispatch logic can stay readable
/// while sharing access to the executor's pipeline cache; pure shader-input
/// math and texture resolution live in `WPEMetalShaderInputs`.
struct WPEMetalShaderDispatcher {
    let executor: WPEMetalRenderExecutor

    func dispatch(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        switch WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader) {
        case "solidcolor":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_solidcolor_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)

        case "solidlayer":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_solidlayer_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)

        case "copy":
            let fragmentName = pass.pass.shader == "commands/copy"
                ? "wpe_copy_fragment"
                : "wpe_util_copy_fragment"
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: fragmentName,
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            if fragmentName == "wpe_copy_fragment" {
                var uniforms = WPEMetalShaderInputs.copyUniforms(for: pass, layer: layer)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPECopyUniforms>.stride, index: 0)
            }

        case "compose":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_compose_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let firstReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let secondReference = pass.textureBindings[1] ?? pass.pass.textures[1] ?? firstReference
            let firstTexture = try WPEMetalShaderInputs.resolve(
                reference: firstReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            let secondTexture = try WPEMetalShaderInputs.resolve(
                reference: secondReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(firstTexture, index: 0)
            encoder.setFragmentTexture(secondTexture, index: 1)
            var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)

        case "effect_colorbalance":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_effect_colorbalance_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = WPEColorBalanceUniforms(
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
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEColorBalanceUniforms>.stride, index: 0)

        case "effect_blur":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_effect_blur_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = WPEBlurUniforms(
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
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEBlurUniforms>.stride, index: 0)

        case "effect_vignette":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_effect_vignette_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = WPEVignetteUniforms(
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
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEVignetteUniforms>.stride, index: 0)

        case "effect_water":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_effect_water_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = WPEWaterUniforms(
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
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEWaterUniforms>.stride, index: 0)

        case "genericimage2":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_genericimage2_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = executor.genericImageUniforms(for: pass, hasMask: false)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)

        case "genericimage4":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_genericimage4_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let primaryRef = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let primary = try WPEMetalShaderInputs.resolve(
                reference: primaryRef,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(primary, index: 0)
            // Slot 1 is the alpha mask (most common combo). When the
            // material doesn't bind it, fall back to slot 0 so the shader
            // sample is still valid Metal — the `hasMask` flag below
            // gates the actual contribution to alpha.
            let maskRef = pass.textureBindings[1] ?? pass.pass.textures[1]
            let hasMask = maskRef != nil
            let mask: MTLTexture
            if let maskRef {
                mask = try WPEMetalShaderInputs.resolve(
                    reference: maskRef,
                    textures: textures,
                    frameState: frameState,
                    currentTargetID: destination.id
                )
            } else {
                mask = primary
            }
            encoder.setFragmentTexture(mask, index: 1)
            var uniforms = executor.genericImageUniforms(for: pass, hasMask: hasMask)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)

        case "effect_opacity":
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_opacity_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPEOpacityUniforms(
                    opacity: WPEMetalShaderInputs.floatScalar(named: ["u_Opacity", "opacity", "amount", "alpha"], in: pass, default: 1)
                )
            )

        case "effect_scroll":
            let speedVec = pass.uniformValues["u_Speed"]?.vectorValue
                ?? pass.pass.constants["u_Speed"]?.vectorValue
                ?? pass.pass.constants["speed"]?.vectorValue
                ?? [0.1, 0]
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_scroll_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPEScrollUniforms(
                    speed: SIMD2<Float>(Float(speedVec.first ?? 0.1), Float(speedVec.dropFirst().first ?? 0)),
                    time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                )
            )

        case "effect_pulse":
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_pulse_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPEPulseUniforms(
                    frequency: WPEMetalShaderInputs.floatScalar(named: ["u_Frequency", "frequency", "speed"], in: pass, default: 1),
                    amplitude: WPEMetalShaderInputs.floatScalar(named: ["u_Amplitude", "amplitude", "amount", "strength"], in: pass, default: 0.25),
                    time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                )
            )

        case "effect_iris":
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_iris_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPEIrisUniforms(
                    radius: WPEMetalShaderInputs.floatScalar(named: ["u_Radius", "radius", "size"], in: pass, default: 0.6),
                    softness: WPEMetalShaderInputs.floatScalar(named: ["u_Softness", "softness", "feather"], in: pass, default: 0.1)
                )
            )

        case "effect_waterwaves":
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_waterwaves_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPEWaterUniforms(
                    amplitude: WPEMetalShaderInputs.floatScalar(named: ["u_Amplitude", "amplitude", "amount", "strength"], in: pass, default: 0.005),
                    frequency: WPEMetalShaderInputs.floatScalar(named: ["u_Frequency", "frequency", "scale"], in: pass, default: 18),
                    speed: WPEMetalShaderInputs.floatScalar(named: ["u_Speed", "speed"], in: pass, default: 1),
                    time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                )
            )

        case "effect_spin":
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_spin_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPESpinUniforms(
                    angularSpeed: WPEMetalShaderInputs.floatScalar(named: ["u_AngularSpeed", "u_Speed", "speed", "angularSpeed"], in: pass, default: 0.5),
                    time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                )
            )

        case "effect_tint":
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_tint_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPETintUniforms(
                    color: WPEMetalShaderInputs.colorVector(for: pass),
                    intensity: WPEMetalShaderInputs.floatScalar(named: ["u_Intensity", "intensity", "amount", "strength"], in: pass, default: 1)
                )
            )

        case "effect_foliagesway":
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_foliagesway_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPEFoliageSwayUniforms(
                    amplitude: WPEMetalShaderInputs.floatScalar(named: ["u_Amplitude", "amplitude", "amount", "strength"], in: pass, default: 0.02),
                    frequency: WPEMetalShaderInputs.floatScalar(named: ["u_Frequency", "frequency", "scale"], in: pass, default: 4),
                    speed: WPEMetalShaderInputs.floatScalar(named: ["u_Speed", "speed"], in: pass, default: 1.5),
                    time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                )
            )

        case "effect_waterripple":
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_waterripple_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPEWaterRippleUniforms(
                    amplitude: WPEMetalShaderInputs.floatScalar(named: ["u_Amplitude", "amplitude", "amount", "strength"], in: pass, default: 0.005),
                    frequency: WPEMetalShaderInputs.floatScalar(named: ["u_Frequency", "frequency", "scale"], in: pass, default: 60),
                    speed: WPEMetalShaderInputs.floatScalar(named: ["u_Speed", "speed"], in: pass, default: 1.0),
                    time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                )
            )

        case "effect_blend":
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_blend_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPEBlendUniforms(
                    color: WPEMetalShaderInputs.colorVector(for: pass),
                    opacity: WPEMetalShaderInputs.floatScalar(named: ["u_Opacity", "opacity", "amount", "strength"], in: pass, default: 1)
                )
            )

        case "effect_waterflow":
            let dirVec = pass.uniformValues["u_Direction"]?.vectorValue
                ?? pass.pass.constants["u_Direction"]?.vectorValue
                ?? [0, 0.1]
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_waterflow_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPEWaterFlowUniforms(
                    direction: SIMD2<Float>(Float(dirVec.first ?? 0), Float(dirVec.dropFirst().first ?? 0.1)),
                    speed: WPEMetalShaderInputs.floatScalar(named: ["u_Speed", "speed"], in: pass, default: 1),
                    time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                )
            )

        case "effect_color_grading":
            func vec4(_ source: [Double]?, fallback: SIMD4<Float>) -> SIMD4<Float> {
                guard let s = source else { return fallback }
                return SIMD4<Float>(
                    Float(s.indices.contains(0) ? s[0] : Double(fallback.x)),
                    Float(s.indices.contains(1) ? s[1] : Double(fallback.y)),
                    Float(s.indices.contains(2) ? s[2] : Double(fallback.z)),
                    Float(s.indices.contains(3) ? s[3] : Double(fallback.w))
                )
            }
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_color_grading_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPEColorGradingUniforms(
                    lift: vec4(pass.uniformValues["u_Lift"]?.vectorValue, fallback: SIMD4<Float>(0, 0, 0, 0)),
                    gamma: vec4(pass.uniformValues["u_Gamma"]?.vectorValue, fallback: SIMD4<Float>(1, 1, 1, 1)),
                    gain: vec4(pass.uniformValues["u_Gain"]?.vectorValue, fallback: SIMD4<Float>(1, 1, 1, 1))
                )
            )

        case "effect_shimmer":
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_shimmer_fragment",
                pass: pass,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                uniforms: WPEShimmerUniforms(
                    speed: WPEMetalShaderInputs.floatScalar(named: ["u_Speed", "speed"], in: pass, default: 4),
                    intensity: WPEMetalShaderInputs.floatScalar(named: ["u_Intensity", "intensity", "amount", "strength"], in: pass, default: 0.2),
                    time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0)
                )
            )

        case "genericparticle":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_genericparticle_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = executor.genericParticleUniforms(for: pass)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericParticleUniforms>.stride, index: 0)

        case "effect_shake":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_effect_shake_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = WPEShakeUniforms(
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
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEShakeUniforms>.stride, index: 0)

        default:
            // Phase 2D-H: custom shader. The injected `WPEShaderCompiling`
            // (default `WPESwiftShaderCompiler`) translates WPE GLSL to
            // MSL on first use; subsequent frames hit the executor's
            // memoization cache.
            let result = try executor.compileCustomShader(for: pass)
            let pipelineState = try executor.translatedPipelineState(
                for: result,
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            )
            encoder.setRenderPipelineState(pipelineState)

            // Texture binding. Lookup chain (highest priority first):
            //   1. `pass.pass.binds[slot]` — effect.json `bind` entry
            //      that explicitly rebinds this slot to an FBO. This is
            //      the multi-pass-effect path: the second pass of a
            //      separable blur or a lightshafts combine reads the
            //      previous pass's FBO from this slot.
            //   2. `pass.textureBindings[slot]` — runtime override
            //      merged in from scene effect overrides.
            //   3. `pass.pass.textures[slot]` — material's `textures: []`
            //      array (the artist-bound input).
            //   4. `pass.pass.source` for slot 0 — implicit "what came
            //      before me on the layer composite chain".
            //   5. Reuse slot 0's texture for unused slots so Metal's
            //      sampler always has a valid binding.
            var primary: MTLTexture? = nil
            for slot in 0..<4 {
                let reference = pass.pass.binds[slot]
                    ?? pass.textureBindings[slot]
                    ?? pass.pass.textures[slot]
                let texture: MTLTexture?
                if let reference {
                    texture = try WPEMetalShaderInputs.resolve(
                        reference: reference,
                        textures: textures,
                        frameState: frameState,
                        currentTargetID: destination.id
                    )
                } else if slot == 0 {
                    // Slot 0 must always be bound; fall back to source.
                    texture = try WPEMetalShaderInputs.resolve(
                        reference: pass.pass.source,
                        textures: textures,
                        frameState: frameState,
                        currentTargetID: destination.id
                    )
                } else {
                    texture = primary  // Reuse for unused slots.
                }
                if slot == 0, let texture { primary = texture }
                encoder.setFragmentTexture(texture, index: slot)
            }

            // Uniform packing. Shaders without uniforms still get a
            // zero-filled buffer bound — the function signature emitted by
            // the transpiler omits the `constant WPEUniforms&` parameter
            // when the layout is empty, so we only bind when needed.
            if !result.uniformLayout.isEmpty {
                var slots = executor.packTranslatedUniforms(for: pass, layout: result.uniformLayout)
                let byteCount = MemoryLayout<SIMD4<Float>>.stride * slots.count
                encoder.setFragmentBytes(&slots, length: byteCount, index: 0)
            }
        }
    }
}
