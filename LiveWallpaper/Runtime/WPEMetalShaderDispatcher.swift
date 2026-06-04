#if !LITE_BUILD
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
        if pass.shader?.isBuiltin == false {
            try dispatchCustomShader(
                pass: pass,
                layer: layer,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat
            )
            return
        }

        switch WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader) {
        case "solidcolor":
            let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
            encoder.setRenderPipelineState(try executor.renderPipeline(
                vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
                fragmentName: "wpe_solidcolor_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
            if usesObjectQuad {
                var quadUniforms = executor.objectQuadUniforms(
                    for: layer,
                    sceneSize: frameState.sceneSize,
                    cameraParallax: frameState.cameraParallax,
                    sourceTexture: destination.texture
                )
                encoder.setVertexBytes(
                    &quadUniforms,
                    length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                    index: 1
                )
            }

        case "solidlayer":
            let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
            encoder.setRenderPipelineState(try executor.renderPipeline(
                vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
                fragmentName: "wpe_solidlayer_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
            if usesObjectQuad {
                var quadUniforms = executor.objectQuadUniforms(
                    for: layer,
                    sceneSize: frameState.sceneSize,
                    cameraParallax: frameState.cameraParallax,
                    sourceTexture: destination.texture
                )
                encoder.setVertexBytes(
                    &quadUniforms,
                    length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                    index: 1
                )
            }

        case "copy":
            let fragmentName = pass.pass.shader == "commands/copy"
                ? "wpe_copy_fragment"
                : "wpe_util_copy_fragment"
            let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
            encoder.setRenderPipelineState(try executor.renderPipeline(
                vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
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
            if usesObjectQuad {
                var quadUniforms = executor.objectQuadUniforms(
                    for: layer,
                    sceneSize: frameState.sceneSize,
                    cameraParallax: frameState.cameraParallax,
                    sourceTexture: texture
                )
                encoder.setVertexBytes(
                    &quadUniforms,
                    length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                    index: 1
                )
            }

        case "compose":
            let firstReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let secondReference = pass.textureBindings[1] ?? pass.pass.textures[1] ?? firstReference
            let isComposeLayerSceneAlias = isSceneCaptureUtilityLayer(layer)
                && isLayerCompositeTarget(pass.pass.target)
                && isSceneAliasReference(firstReference)
            if isComposeLayerSceneAlias {
                // WPE passthrough utility parity: draw a fullscreen quad and copy
                // the captured full-frame buffer 1:1 at screen UV (+ CLEARALPHA),
                // ignoring the layer transform (which positions downstream effects).
                encoder.setRenderPipelineState(try executor.renderPipeline(
                    fragmentName: "wpe_composelayer_fragment",
                    blendMode: pass.pass.blending,
                    colorPixelFormat: destination.texture.pixelFormat,
                    depthPixelFormat: depthPixelFormat
                ))
                let firstTexture = try WPEMetalShaderInputs.resolve(
                    reference: firstReference,
                    textures: textures,
                    frameState: frameState,
                    currentTargetID: destination.id
                )
                encoder.setFragmentTexture(firstTexture, index: 0)
                var uniforms = WPEComposeLayerUniforms(
                    flags: SIMD4<Float>(clearAlphaValue(for: pass), 0, 0, 0)
                )
                encoder.setFragmentBytes(
                    &uniforms,
                    length: MemoryLayout<WPEComposeLayerUniforms>.stride,
                    index: 0
                )
            } else {
                encoder.setRenderPipelineState(try executor.renderPipeline(
                    fragmentName: "wpe_compose_fragment",
                    blendMode: pass.pass.blending,
                    colorPixelFormat: destination.texture.pixelFormat,
                    depthPixelFormat: depthPixelFormat
                ))
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
            }

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
            let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
            encoder.setRenderPipelineState(try executor.renderPipeline(
                vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
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
            var uniforms = executor.genericImageUniforms(for: pass, layer: layer, hasMask: false)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)
            if usesObjectQuad {
                var quadUniforms = executor.objectQuadUniforms(
                    for: layer,
                    sceneSize: frameState.sceneSize,
                    cameraParallax: frameState.cameraParallax,
                    sourceTexture: texture
                )
                encoder.setVertexBytes(
                    &quadUniforms,
                    length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                    index: 1
                )
            }

        case "genericimage4":
            let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
            encoder.setRenderPipelineState(try executor.renderPipeline(
                vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
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
            WPESceneDebugArtifacts.shared.recordTextureBinding(
                passID: pass.pass.id,
                shader: pass.pass.shader,
                slot: 0,
                reference: primaryRef,
                texture: primary,
                fallbackToPrimary: false
            )
            encoder.setFragmentTexture(primary, index: 0)
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
                WPESceneDebugArtifacts.shared.recordTextureBinding(
                    passID: pass.pass.id,
                    shader: pass.pass.shader,
                    slot: 1,
                    reference: maskRef,
                    texture: mask,
                    fallbackToPrimary: false
                )
            } else {
                mask = primary
                WPESceneDebugArtifacts.shared.recordTextureBinding(
                    passID: pass.pass.id,
                    shader: pass.pass.shader,
                    slot: 1,
                    reference: nil,
                    texture: mask,
                    fallbackToPrimary: true
                )
            }
            encoder.setFragmentTexture(mask, index: 1)
            var uniforms = executor.genericImageUniforms(for: pass, layer: layer, hasMask: hasMask)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)
            if usesObjectQuad {
                var quadUniforms = executor.objectQuadUniforms(
                    for: layer,
                    sceneSize: frameState.sceneSize,
                    cameraParallax: frameState.cameraParallax,
                    sourceTexture: primary
                )
                encoder.setVertexBytes(
                    &quadUniforms,
                    length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                    index: 1
                )
            }

        case "effect_opacity":
            try executor.dispatchOpacityEffect(
                pass: pass,
                layer: layer,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat
            )

        case "effect_scroll":
            let speedVec = pass.uniformValues["u_Speed"]?.vectorValue
                ?? pass.pass.constants["u_Speed"]?.vectorValue
                ?? pass.pass.constants["speed"]?.vectorValue
                ?? [0.1, 0]
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_scroll_fragment",
                pass: pass,
                layer: layer,
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
                layer: layer,
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
                layer: layer,
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
            // WPE's waterwaves.vert sets v_Direction = rotate((0,1), g_Direction[rad]).
            let waveAngle = WPEMetalShaderInputs.floatScalar(named: ["g_Direction", "direction"], in: pass, default: 0)
            try executor.dispatchWaterWavesEffect(
                pass: pass,
                layer: layer,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat,
                time: WPEMetalShaderInputs.floatScalar(named: "g_Time", in: pass, default: 0),
                speed: WPEMetalShaderInputs.floatScalar(named: ["g_Speed", "speed"], in: pass, default: 5),
                scale: WPEMetalShaderInputs.floatScalar(named: ["g_Scale", "scale"], in: pass, default: 200),
                strength: WPEMetalShaderInputs.floatScalar(named: ["g_Strength", "strength"], in: pass, default: 0.1),
                exponent: WPEMetalShaderInputs.floatScalar(named: ["g_Exponent", "exponent"], in: pass, default: 1),
                direction: SIMD2<Float>(-sin(waveAngle), cos(waveAngle)),
                debugMode: WPEWaterWavesDebugMode.current.rawValue
            )

        case "effect_spin":
            try executor.dispatchSingleSampleEffect(
                fragmentName: "wpe_effect_spin_fragment",
                pass: pass,
                layer: layer,
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
                layer: layer,
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
                layer: layer,
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
                layer: layer,
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
                layer: layer,
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
                layer: layer,
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
                layer: layer,
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
                layer: layer,
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
            let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
            encoder.setRenderPipelineState(try executor.renderPipeline(
                vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
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
            if usesObjectQuad {
                var quadUniforms = executor.objectQuadUniforms(
                    for: layer,
                    sceneSize: frameState.sceneSize,
                    cameraParallax: frameState.cameraParallax,
                    sourceTexture: texture
                )
                encoder.setVertexBytes(
                    &quadUniforms,
                    length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                    index: 1
                )
            }

        default:
            try dispatchCustomShader(
                pass: pass,
                layer: layer,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat
            )
        }
    }

    private func dispatchCustomShader(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let result = try executor.compileCustomShader(for: pass)
        // Dev-only: dump every transpiled layer's MSL + uniform/sampler interface
        // so it can be cross-checked against the Windows RenderDoc oracle
        // (tools/wpe-oracle shader-interface.md). No-op unless scene-debug is on.
        if WPESceneDebugArtifacts.shared.isEnabled {
            WPESceneDebugArtifacts.shared.recordNoteOnce(
                name: "msl-\(pass.pass.id)-\(pass.pass.shader).metal",
                contents: result.mslSource
            )
            var iface = "shader=\(pass.pass.shader) pass=\(pass.pass.id)\n"
            iface += "vertexFunction=\(result.vertexFunctionName)\n"
            iface += "fragmentFunction=\(result.fragmentFunctionName)\n"
            iface += "samplerNames=\(result.samplerNames)\n"
            iface += "uniformLayout (name | glslType | slot | slotCount | arrayLength | material):\n"
            for slot in result.uniformLayout {
                iface += "  \(slot.name) | \(slot.glslType) | \(slot.slot) | \(slot.slotCount)"
                    + " | \(slot.arrayLength.map(String.init) ?? "-") | \(slot.materialName ?? "-")\n"
            }
            WPESceneDebugArtifacts.shared.recordNoteOnce(
                name: "iface-\(pass.pass.id)-\(pass.pass.shader).txt",
                contents: iface
            )
        }
        let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        let isWaveLikePass = Self.isWaveLikePass(pass)
        let isWaterWavesPass = Self.isWaterWavesPass(pass)
        // The transpiler is fragment-only: it always uses wpe_fullscreen_vertex and
        // synthesizes v_TexCoord / v_Direction in the fragment (it does NOT run the
        // scene .vert). Record which path waterwaves takes live + whether the mask is bound.
        if isWaterWavesPass {
            WPESceneDebugArtifacts.shared.setWaterWavesPath("Transpiled")
        }
        if isWaveLikePass {
            let maskLive = Self.hasExplicitTextureSlot(1, in: pass)
            WPESceneDebugArtifacts.shared.appendLog(
                "🌊 [WPE.fx.vtx] \(pass.pass.shader) target=\(pass.pass.target) "
                    + "vertex=\(usesObjectQuad ? "builtin_object_quad" : "fullscreen+synthesized-varyings") "
                    + "maskSlot1=\(maskLive) MASK=\(pass.comboValues["MASK"] ?? 0)",
                level: .warning
            )
        }

        var primary: MTLTexture? = nil
        var resolvedTexturesBySlot: [Int: MTLTexture] = [:]
        #if !LITE_BUILD && DEBUG
        var canonicalTextureBindings: [WPECanonicalTraceRecorder.TextureBindingInput] = []
        #endif
        for slot in 0..<WPEShaderTranspiler.customTextureSlotCount {
            // `textureBindings` is the pipeline-builder's *normalized* binding
            // table: it already rewrites an effect-bind `previous` to the pass's
            // source (the layer composite feeding this effect). The raw
            // `pass.pass.binds` still carries the literal `.previous`, which
            // resolves to the black "bootstrap previous" texture on a target
            // with no prior-frame history (e.g. shine_combine's slot-1 albedo
            // bound `{name:"previous"}` → whole layer renders black). Prefer the
            // normalized table first, matching every other dispatch path
            // (`textureBindings[slot] ?? textures[slot] ?? source`).
            let reference = pass.textureBindings[slot]
                ?? pass.pass.binds[slot]
                ?? pass.pass.textures[slot]
            let texture: MTLTexture?
            let resolvedReference: WPETextureReference?
            let fallbackToPrimary: Bool
            if let reference {
                texture = try WPEMetalShaderInputs.resolve(
                    reference: reference,
                    textures: textures,
                    frameState: frameState,
                    currentTargetID: destination.id
                )
                resolvedReference = reference
                fallbackToPrimary = false
            } else if slot == 0 {
                texture = try WPEMetalShaderInputs.resolve(
                    reference: pass.pass.source,
                    textures: textures,
                    frameState: frameState,
                    currentTargetID: destination.id
                )
                resolvedReference = pass.pass.source
                fallbackToPrimary = false
            } else {
                texture = primary
                resolvedReference = nil
                fallbackToPrimary = true
            }
            if slot == 0, let texture { primary = texture }
            WPESceneDebugArtifacts.shared.recordTextureBinding(
                passID: pass.pass.id,
                shader: pass.pass.shader,
                slot: slot,
                reference: resolvedReference,
                texture: texture,
                fallbackToPrimary: fallbackToPrimary
            )
            encoder.setFragmentTexture(texture, index: slot)
            if let texture {
                resolvedTexturesBySlot[slot] = texture
            }
            #if !LITE_BUILD && DEBUG
            canonicalTextureBindings.append(WPECanonicalTraceRecorder.TextureBindingInput(
                slot: slot,
                name: result.samplerNames.indices.contains(slot) ? result.samplerNames[slot] : nil,
                reference: resolvedReference,
                texture: texture,
                fallbackToPrimary: fallbackToPrimary
            ))
            #endif
        }

        var packedUniformSlots: [SIMD4<Float>] = []
        if !result.uniformLayout.isEmpty {
            packedUniformSlots = executor.packTranslatedUniforms(
                for: pass,
                layout: result.uniformLayout,
                texturesBySlot: resolvedTexturesBySlot,
                destinationTexture: usesObjectQuad ? (primary ?? destination.texture) : destination.texture
            )
        }
        #if !LITE_BUILD && DEBUG
        WPECanonicalTraceRecorder.shared.recordCustomPass(
            pass: pass,
            destination: destination,
            result: result,
            textureBindings: canonicalTextureBindings,
            packedUniformSlots: packedUniformSlots,
            usesObjectQuad: usesObjectQuad
        )
        #endif

        // Phase A: log the GPU-bound uniforms for waterwaves passes so the live values
        // (g_Time/g_Speed/g_Scale/g_Direction/g_Strength/g_Texture1Resolution) can be
        // inspected on-device, plus dump the translated MSL once.
        if isWaterWavesPass && WPEWaterWavesTrace.isEnabled {
            Self.traceWaterWavesPass(
                pass: pass,
                result: result,
                layout: result.uniformLayout,
                slots: packedUniformSlots,
                texturesBySlot: resolvedTexturesBySlot
            )
        }

        // Phase B: when the Developer Tools "Waterwaves debug" picker is on, visualize the
        // effect on the REAL (transpiled) path by drawing the builtin debug fragment with the
        // packed uniforms, instead of the transpiled shader. Off in production.
        let waterWavesDebugMode = isWaterWavesPass ? WPEWaterWavesDebugMode.current : .off
        if waterWavesDebugMode != .off {
            try dispatchWaterWavesDebugOverlay(
                pass: pass,
                destination: destination,
                sourceTexture: resolvedTexturesBySlot[0] ?? primary,
                maskTexture: Self.hasExplicitTextureSlot(1, in: pass)
                    ? resolvedTexturesBySlot[1]
                    : (resolvedTexturesBySlot[0] ?? primary),
                hasMask: Self.hasExplicitTextureSlot(1, in: pass),
                layout: result.uniformLayout,
                slots: packedUniformSlots,
                debugMode: waterWavesDebugMode,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat
            )
            return
        }

        let pipelineState = try executor.translatedPipelineState(
            for: result,
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : nil,
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        )
        encoder.setRenderPipelineState(pipelineState)

        if !packedUniformSlots.isEmpty {
            var slots = packedUniformSlots
            let byteCount = MemoryLayout<SIMD4<Float>>.stride * slots.count
            encoder.setFragmentBytes(&slots, length: byteCount, index: 0)
        }
        if usesObjectQuad {
            var quadUniforms = executor.objectQuadUniforms(
                for: layer,
                sceneSize: frameState.sceneSize,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: primary ?? destination.texture
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
    }

    /// Phase B helper: render the builtin waterwaves debug fragment (mask/overlay/displacement/
    /// solid visualizations) onto the live transpiler-path target, using the uniforms packed for
    /// the real shader. Lets the Developer Tools debug picker affect the actual on-screen path.
    private func dispatchWaterWavesDebugOverlay(
        pass: WPEPreparedRenderPass,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        sourceTexture: MTLTexture?,
        maskTexture: MTLTexture?,
        hasMask: Bool,
        layout: [WPEUniformSlot],
        slots: [SIMD4<Float>],
        debugMode: WPEWaterWavesDebugMode,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        guard let sourceTexture else {
            throw WPEMetalRenderExecutorError.missingTexture(pass.pass.source)
        }
        let resolvedMaskTexture = maskTexture ?? sourceTexture
        encoder.setRenderPipelineState(try executor.renderPipeline(
            vertexName: "wpe_fullscreen_vertex",
            fragmentName: "wpe_effect_waterwaves_fragment",
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(resolvedMaskTexture, index: 1)

        let angle = Self.packedScalar(named: "g_Direction", in: layout, slots: slots) ?? 0
        let direction = SIMD2<Float>(-sin(angle), cos(angle))
        var uniforms = WPEWaterWavesUniforms(
            time: Self.packedScalar(named: "g_Time", in: layout, slots: slots) ?? 0,
            speed: Self.packedScalar(named: "g_Speed", in: layout, slots: slots) ?? 5,
            scale: Self.packedScalar(named: "g_Scale", in: layout, slots: slots) ?? 200,
            strength: Self.packedScalar(named: "g_Strength", in: layout, slots: slots) ?? 0.1,
            exponent: Self.packedScalar(named: "g_Exponent", in: layout, slots: slots) ?? 1,
            directionX: direction.x,
            directionY: direction.y,
            hasMask: hasMask ? 1 : 0,
            debugMode: debugMode.rawValue,
            texture1Resolution: Self.packedVector(named: "g_Texture1Resolution", in: layout, slots: slots)
                ?? Self.textureResolutionVector(for: resolvedMaskTexture)
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<WPEWaterWavesUniforms>.stride,
            index: 0
        )
        // The caller (WPEMetalRenderExecutor.encode) issues the fullscreen draw after dispatch returns.
    }

    private static func traceWaterWavesPass(
        pass: WPEPreparedRenderPass,
        result: WPEShaderCompileResult,
        layout: [WPEUniformSlot],
        slots: [SIMD4<Float>],
        texturesBySlot: [Int: MTLTexture]
    ) {
        WPESceneDebugArtifacts.shared.recordNoteOnce(
            name: "msl-\(pass.pass.id)-\(pass.pass.shader).metal",
            contents: result.mslSource
        )

        let angle = packedScalar(named: "g_Direction", in: layout, slots: slots)
        let direction = angle.map { SIMD2<Float>(-sin($0), cos($0)) }
        let strength = packedScalar(named: "g_Strength", in: layout, slots: slots)
        let maxUV = strength.map { $0 * $0 }
        WPESceneDebugArtifacts.shared.appendLog(
            "[waterwaves.trace] pass=\(pass.pass.id)"
                + " combos=\(pass.comboValues)"
                + " samplers=\(result.samplerNames)"
                + " tex0=\(textureSizeDescription(texturesBySlot[0]))"
                + " tex1=\(textureSizeDescription(texturesBySlot[1]))"
                + " g_Time=\(scalarDescription(packedScalar(named: "g_Time", in: layout, slots: slots)))"
                + " g_Direction=\(scalarDescription(angle))"
                + " dir=\(vector2Description(direction))"
                + " g_Speed=\(scalarDescription(packedScalar(named: "g_Speed", in: layout, slots: slots)))"
                + " g_Scale=\(scalarDescription(packedScalar(named: "g_Scale", in: layout, slots: slots)))"
                + " g_Strength=\(scalarDescription(strength))"
                + " g_Exponent=\(scalarDescription(packedScalar(named: "g_Exponent", in: layout, slots: slots)))"
                + " g_Texture1Resolution=\(vector4Description(packedVector(named: "g_Texture1Resolution", in: layout, slots: slots)))"
                + " maxUV=\(scalarDescription(maxUV))",
            level: .warning
        )
    }

    private static func isWaterWavesPass(_ pass: WPEPreparedRenderPass) -> Bool {
        WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader) == "effect_waterwaves"
    }

    private static func isWaveLikePass(_ pass: WPEPreparedRenderPass) -> Bool {
        if isWaterWavesPass(pass) { return true }
        let shader = pass.pass.shader.lowercased()
        return shader.contains("wave") || shader.contains("flutter")
    }

    private static func hasExplicitTextureSlot(_ slot: Int, in pass: WPEPreparedRenderPass) -> Bool {
        pass.textureBindings[slot] != nil
            || pass.pass.textures[slot] != nil
            || pass.pass.binds[slot] != nil
    }

    private static func packedScalar(
        named name: String,
        in layout: [WPEUniformSlot],
        slots: [SIMD4<Float>]
    ) -> Float? {
        packedVector(named: name, in: layout, slots: slots)?.x
    }

    private static func packedVector(
        named name: String,
        in layout: [WPEUniformSlot],
        slots: [SIMD4<Float>]
    ) -> SIMD4<Float>? {
        guard let uniform = layout.first(where: { $0.name == name }),
              slots.indices.contains(uniform.slot) else {
            return nil
        }
        return slots[uniform.slot]
    }

    private static func textureResolutionVector(for texture: MTLTexture?) -> SIMD4<Float> {
        guard let texture else { return SIMD4<Float>(1, 1, 1, 1) }
        let resolution = WPEMetalTextureMetadataRegistry.shared.resolution(for: texture)
        return SIMD4<Float>(
            Float(resolution.textureWidth),
            Float(resolution.textureHeight),
            Float(resolution.imageWidth),
            Float(resolution.imageHeight)
        )
    }

    private static func textureSizeDescription(_ texture: MTLTexture?) -> String {
        guard let texture else { return "nil" }
        return "\(texture.width)x\(texture.height)"
    }

    private static func scalarDescription(_ value: Float?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.6f", value)
    }

    private static func vector2Description(_ value: SIMD2<Float>?) -> String {
        guard let value else { return "nil" }
        return String(format: "(%.6f,%.6f)", value.x, value.y)
    }

    private static func vector4Description(_ value: SIMD4<Float>?) -> String {
        guard let value else { return "nil" }
        return String(format: "(%.3f,%.3f,%.3f,%.3f)", value.x, value.y, value.z, value.w)
    }

    private func isSceneCaptureUtilityLayer(_ layer: WPERenderLayer) -> Bool {
        WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath(layer.imagePath)
    }

    private func isLayerCompositeTarget(_ target: WPERenderTarget) -> Bool {
        if case .layerComposite = target {
            return true
        }
        return false
    }

    private func isSceneAliasReference(_ reference: WPETextureReference) -> Bool {
        guard case .fbo(let name) = reference else {
            return false
        }
        return WPEMetalShaderInputs.isSceneAliasName(name)
    }

    private func clearAlphaValue(for pass: WPEPreparedRenderPass) -> Float {
        comboValue(named: "CLEARALPHA", in: pass) == 1 ? 1 : 0
    }

    private func comboValue(named name: String, in pass: WPEPreparedRenderPass) -> Int {
        if let value = pass.comboValues[name] ?? pass.pass.combos[name] {
            return value
        }
        let uppercased = name.uppercased()
        for (key, value) in pass.comboValues where key.uppercased() == uppercased {
            return value
        }
        for (key, value) in pass.pass.combos where key.uppercased() == uppercased {
            return value
        }
        return 0
    }

}
#endif
