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
            let usesLegacyRegion = isComposeLayerSceneAlias && frameState.legacyComposeLayer
            if isComposeLayerSceneAlias && !usesLegacyRegion {
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
                if usesLegacyRegion {
                    Logger.warning(
                        "WPE Metal compose layer fallback: legacy region path for scene=\(frameState.sceneID ?? "unknown") layer=\(layer.objectID)",
                        category: .wpeRender
                    )
                }
                let usesSceneCaptureRegion = usesLegacyRegion
                    && (isSceneAliasReference(firstReference) || isSceneAliasReference(secondReference))
                encoder.setRenderPipelineState(try executor.renderPipeline(
                    fragmentName: usesSceneCaptureRegion ? "wpe_compose_region_fragment" : "wpe_compose_fragment",
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
                if usesSceneCaptureRegion {
                    let regionRect = executor.sceneCaptureUVRect(
                        for: layer,
                        sceneSize: frameState.sceneSize,
                        sourceTexture: firstTexture
                    )
                    let localRect = SIMD4<Float>(0, 0, 1, 1)
                    var uniforms = WPEComposeRegionUniforms(
                        color: WPEMetalShaderInputs.colorVector(for: pass),
                        texture0UVRect: isSceneAliasReference(firstReference) ? regionRect : localRect,
                        texture1UVRect: isSceneAliasReference(secondReference) ? regionRect : localRect
                    )
                    encoder.setFragmentBytes(
                        &uniforms,
                        length: MemoryLayout<WPEComposeRegionUniforms>.stride,
                        index: 0
                    )
                } else {
                    var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
                }
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
        let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        // Diagnostic for the hair/cloth "ghost": a displacement effect whose
        // custom .vert builds v_Direction / a resolution-scaled mask UV gets
        // that .vert discarded when usesObjectQuad forces the builtin
        // object-quad vertex (scene-target pass). Logs which vertex each
        // waterwaves-class pass actually runs + whether the mask is live.
        if pass.pass.shader.lowercased().contains("wave")
            || pass.pass.shader.lowercased().contains("flutter") {
            let maskLive = pass.textureBindings[1] != nil || pass.pass.textures[1] != nil
            WPESceneDebugArtifacts.shared.appendLog(
                "🌊 [WPE.fx.vtx] \(pass.pass.shader) target=\(pass.pass.target) "
                    + "vertex=\(usesObjectQuad ? "builtin_object_quad(drops v_Direction/.zw)" : "custom_vert") "
                    + "maskSlot1=\(maskLive) MASK=\(pass.comboValues["MASK"] ?? 0)",
                level: .warning
            )
        }
        let pipelineState = try executor.translatedPipelineState(
            for: result,
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : nil,
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        )
        encoder.setRenderPipelineState(pipelineState)

        var primary: MTLTexture? = nil
        var resolvedTexturesBySlot: [Int: MTLTexture] = [:]
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
        }

        if !result.uniformLayout.isEmpty {
            var slots = executor.packTranslatedUniforms(
                for: pass,
                layout: result.uniformLayout,
                texturesBySlot: resolvedTexturesBySlot,
                destinationTexture: usesObjectQuad ? (primary ?? destination.texture) : destination.texture
            )
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

    private func isSceneCaptureUtilityLayer(_ layer: WPERenderLayer) -> Bool {
        WPEMetalComposeLayerCompatibility.isSceneCaptureUtilityModelPath(layer.imagePath)
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
