#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
/// Dispatches a prepared pass onto a Metal pipeline state. Shares the executor's
/// pipeline cache; shader-input math and texture resolution live in `WPEMetalShaderInputs`.
///
/// Ordinal texture-slot contract (fragment texture indices; each role is fixed
/// per case — the local `*Slot` constants at multi-input call sites name that
/// case's roles, they are not a shared vocabulary across cases):
/// - Compose family: `solidcolor`/`solidlayer` bind no texture; `copy` binds
///   slot 0 = pass source; `compose` binds slot 0 = first source and slot 1 =
///   second source (an absent second binding falls back to the first
///   reference); the scene-capture compose-layer variants bind slot 0 only.
/// - Image family: `genericimage2` binds slot 0 = image; `genericimage4` binds
///   slot 0 = image and slot 1 = mask (an absent mask rebinds the slot-0
///   texture and clears the has-mask uniform).
/// - Particle family: `genericparticle` binds slot 0 = sprite texture.
/// - Effect family: slot 0 = effect input (`textureBindings[0] ?? textures[0]
///   ?? source`); the masked effects (`effect_opacity`, `effect_waterwaves`)
///   add slot 1 = opacity mask, falling back to the source texture with
///   has-mask cleared. Per-effect fragment names, slot bindings, and uniform
///   builders live in the B2 data table (`WPEMetalEffectDispatchTable.swift`);
///   the switch keeps only the compose/image/particle families and the
///   custom/transpiled fallback as code paths.
/// - Custom/transpiled fallback: slots 0..<`WPEShaderTranspiler.customTextureSlotCount`,
///   each resolved `textureBindings[slot] ?? binds[slot] ?? textures[slot]`;
///   slot 0 falls back to the pass source, empty higher slots rebind the
///   slot-0 primary, and a per-slot sampler is bound at the matching index.
///   `godrays_combine` is fixed: slot 0 = rays, slot 1 = albedo, slot 2 = base
///   (an absent base rebinds albedo and sets the use-base uniform).
/// Buffer indices are positional too: fragment uniforms at buffer 0,
/// object/shape-quad vertex uniforms at buffer 1, skew params at buffer 2.
///
/// Puppet/model and MSDF text passes never reach this dispatcher — the executor
/// encodes them directly (scene-model / puppet-material / puppet-scene-composite
/// passes, `drawMSDFText`) before constructing it, so those families have no
/// cases here.
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

        guard let kind = WPEBuiltinShaderKind(
            rawValue: WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader)
        ) else {
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

        switch kind {
        // ADR-001 B2: effect cases migrated to the data table
        // (`WPEMetalEffectDispatchTable.swift`). The snapshot test on
        // `WPEEffectDispatchDescriptor.table` pins that every kind listed here
        // has an entry, so the force-unwrap cannot trip at runtime.
        case .effectColorBalance, .effectBlur, .effectVignette, .effectWater,
             .effectOpacity, .effectScroll, .effectPulse, .effectIris,
             .effectWaterWaves, .effectSpin, .effectTint, .effectFoliageSway,
             .effectWaterRipple, .effectBlend, .effectWaterFlow,
             .effectColorGrading, .effectShimmer, .effectShake:
            try dispatchEffect(
                WPEEffectDispatchDescriptor.table[kind]!,
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .solidColor:
            try dispatchSolidColor(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .solidLayer:
            try dispatchSolidLayer(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .copy:
            try dispatchCopy(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .blendComposite:
            try dispatchBlendComposite(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .compose:
            try dispatchCompose(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .genericImage2:
            try dispatchGenericImage2(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .genericImage4:
            try dispatchGenericImage4(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .genericParticle:
            try dispatchGenericParticle(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        }
    }

    // MARK: - Compose family

    private func dispatchSolidColor(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
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
                sceneSize: executor.objectQuadSceneSize(
                    for: pass,
                    layer: layer,
                    destination: destination,
                    frameState: frameState
                ),
                cameraParallax: frameState.cameraParallax,
                sourceTexture: destination.texture,
                cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
    }

    private func dispatchSolidLayer(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
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
                sceneSize: executor.objectQuadSceneSize(
                    for: pass,
                    layer: layer,
                    destination: destination,
                    frameState: frameState
                ),
                cameraParallax: frameState.cameraParallax,
                sourceTexture: destination.texture,
                cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
    }

    /// Composites a destination-reading blend (Overlay et al) — see
    /// `wpe_blend_composite_fragment`. Slot 4 carries the scene snapshot to
    /// mirror WPE's `g_Texture4` binding.
    private func dispatchBlendComposite(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        encoder.setRenderPipelineState(try executor.renderPipeline(
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: "wpe_blend_composite_fragment",
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))

        let layerReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let layerTexture = try WPEMetalShaderInputs.resolve(
            reference: layerReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        encoder.setFragmentTexture(layerTexture, index: 0)

        guard let sceneReference = pass.textureBindings[4] ?? pass.pass.textures[4] else {
            throw WPEMetalRenderExecutorError.missingTexture(layerReference)
        }
        let sceneTexture = try WPEMetalShaderInputs.resolve(
            reference: sceneReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        encoder.setFragmentTexture(sceneTexture, index: 4)

        var uniforms = WPEBlendCompositeUniforms(
            blendMode: Int32(WPEMetalShaderInputs.floatScalar(
                named: "g_BlendMode",
                in: pass,
                default: 0
            ))
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEBlendCompositeUniforms>.stride, index: 0)

        if usesObjectQuad {
            var quadUniforms = executor.objectQuadUniforms(
                for: layer,
                sceneSize: executor.objectQuadSceneSize(
                    for: pass,
                    layer: layer,
                    destination: destination,
                    frameState: frameState
                ),
                cameraParallax: frameState.cameraParallax,
                sourceTexture: layerTexture,
                cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
    }

    private func dispatchCopy(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
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
        // wpe_copy_fragment samples 1:1 and takes no fragment uniform buffer.
        if usesObjectQuad {
            var quadUniforms = executor.objectQuadUniforms(
                for: layer,
                sceneSize: executor.objectQuadSceneSize(
                    for: pass,
                    layer: layer,
                    destination: destination,
                    frameState: frameState
                ),
                cameraParallax: frameState.cameraParallax,
                sourceTexture: texture,
                cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
    }

    private func dispatchCompose(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let firstReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let secondReference = pass.textureBindings[1] ?? pass.pass.textures[1] ?? firstReference
        let isSingleTextureComposeLayer = isSceneCaptureUtilityLayer(layer)
            && isLayerCompositeTarget(pass.pass.target)
            && (isSceneAliasReference(firstReference) || isGroupCompositeSourceReference(firstReference, layer: layer))
        let isLocalSceneCaptureComposeLayer = isSingleTextureComposeLayer
            && layer.groupCompositeSource == nil
            && isSceneAliasReference(firstReference)
            && executor.sceneCaptureUtilityOutputGeometry(for: layer) == .subregion
        if isLocalSceneCaptureComposeLayer {
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_local_scene_capture_fragment",
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
            var uniforms = executor.objectQuadUniforms(
                for: layer,
                sceneSize: frameState.sceneSize,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: firstTexture,
                cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
            )
            uniforms.uvSignAndPadding.z = clearAlphaValue(for: pass)
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 0
            )
        } else if isSingleTextureComposeLayer {
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
            let firstComposeSlot = 0
            let secondComposeSlot = 1
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
            let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
            encoder.setRenderPipelineState(try executor.renderPipeline(
                vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
                fragmentName: "wpe_compose_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            encoder.setFragmentTexture(firstTexture, index: firstComposeSlot)
            encoder.setFragmentTexture(secondTexture, index: secondComposeSlot)
            var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
            if usesObjectQuad {
                var quadUniforms = executor.objectQuadUniforms(
                    for: layer,
                    sceneSize: executor.objectQuadSceneSize(
                        for: pass,
                        layer: layer,
                        destination: destination,
                        frameState: frameState
                    ),
                    cameraParallax: frameState.cameraParallax,
                    sourceTexture: firstTexture,
                    cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
                )
                encoder.setVertexBytes(
                    &quadUniforms,
                    length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                    index: 1
                )
            }
        }
    }

    // MARK: - Image family

    private func dispatchGenericImage2(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
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
        var uniforms = executor.genericImageUniforms(
            for: pass,
            layer: layer,
            hasMask: false,
            sourceTexture: texture
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)
        if usesObjectQuad {
            var quadUniforms = executor.objectQuadUniforms(
                for: layer,
                sceneSize: executor.objectQuadSceneSize(
                    for: pass,
                    layer: layer,
                    destination: destination,
                    frameState: frameState
                ),
                cameraParallax: frameState.cameraParallax,
                sourceTexture: texture,
                cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
    }

    private func dispatchGenericImage4(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let primarySlot = 0
        let maskSlot = 1
        let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        encoder.setRenderPipelineState(try executor.renderPipeline(
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: "wpe_genericimage4_fragment",
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        let primaryRef = pass.textureBindings[primarySlot] ?? pass.pass.textures[primarySlot] ?? pass.pass.source
        let primary = try WPEMetalShaderInputs.resolve(
            reference: primaryRef,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        WPESceneDebugArtifacts.shared.recordTextureBinding(
            passID: pass.pass.id,
            shader: pass.pass.shader,
            slot: primarySlot,
            reference: primaryRef,
            texture: primary,
            fallbackToPrimary: false
        )
        encoder.setFragmentTexture(primary, index: primarySlot)
        let maskRef = pass.textureBindings[maskSlot] ?? pass.pass.textures[maskSlot]
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
                slot: maskSlot,
                reference: maskRef,
                texture: mask,
                fallbackToPrimary: false
            )
        } else {
            mask = primary
            WPESceneDebugArtifacts.shared.recordTextureBinding(
                passID: pass.pass.id,
                shader: pass.pass.shader,
                slot: maskSlot,
                reference: nil,
                texture: mask,
                fallbackToPrimary: true
            )
        }
        encoder.setFragmentTexture(mask, index: maskSlot)
        var uniforms = executor.genericImageUniforms(
            for: pass,
            layer: layer,
            hasMask: hasMask,
            sourceTexture: primary,
            maskTexture: hasMask ? mask : nil
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)
        if usesObjectQuad {
            var quadUniforms = executor.objectQuadUniforms(
                for: layer,
                sceneSize: executor.objectQuadSceneSize(
                    for: pass,
                    layer: layer,
                    destination: destination,
                    frameState: frameState
                ),
                cameraParallax: frameState.cameraParallax,
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

    // MARK: - Particle family

    private func dispatchGenericParticle(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
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
    }

    // MARK: - Custom / transpiled fallback

    private func dispatchCustomShader(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        if Self.isGodraysCombineShader(pass.pass.shader) {
            try dispatchGodraysCombine(
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

        let result = try executor.compileCustomShader(for: pass)
        // Dump transpiled MSL + uniform/sampler interface for cross-check against the
        // Windows RenderDoc oracle (tools/wpe-oracle shader-interface.md). Scene-debug only.
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
        let usesShapeQuad = executor.usesShapeQuadGeometry(for: pass, layer: layer, frameState: frameState)
        let usesObjectQuad = !usesShapeQuad
            && executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        let isWaveLikePass = Self.isWaveLikePass(pass)
        // The transpiler is fragment-only: it always uses wpe_fullscreen_vertex and
        // synthesizes v_TexCoord / v_Direction in the fragment (it does NOT run the scene .vert).
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
            // Bind the matching per-slot sampler (`wpeSampler<slot>`): address mode
            // (clamp/repeat) + filter (linear/nearest) come from the texture's TEXI
            // flags. Tiling maps sampled at time-scrolled UVs (water-normal, noise,
            // flow) now repeat instead of clamping to a frozen edge.
            encoder.setFragmentSamplerState(
                executor.customShaderSamplerState(for: texture),
                index: slot
            )
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
                destinationTexture: (usesObjectQuad || usesShapeQuad) ? (primary ?? destination.texture) : destination.texture
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

        // WPE `effects/skew` MODE=1 displaces the quad GEOMETRY in the vertex
        // stage; the transpiled fragment leaves the UV untouched, so a plain
        // object quad would drop the effect. Route it through the skew vertex
        // (object-quad transform + WPE corner displacement) when it uses the
        // object quad (group/scene target with a layer transform).
        let usesSkewVertex = usesObjectQuad && executor.isVertexSkewPass(pass)
        let vertexName: String?
        if usesShapeQuad {
            vertexName = "wpe_shape_quad_vertex"
        } else if usesSkewVertex {
            vertexName = "wpe_skew_object_quad_vertex"
        } else if usesObjectQuad {
            vertexName = "wpe_object_quad_vertex"
        } else {
            vertexName = nil
        }
        let pipelineState = try executor.translatedPipelineState(
            for: result,
            vertexName: vertexName,
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        )
        encoder.setRenderPipelineState(pipelineState)

        if !packedUniformSlots.isEmpty {
            executor.bindTranslatedUniformSlots(packedUniformSlots, to: encoder)
        }
        if usesShapeQuad {
            var shapeUniforms = executor.shapeQuadUniforms(
                for: layer,
                sceneSize: executor.objectQuadSceneSize(
                    for: pass,
                    layer: layer,
                    destination: destination,
                    frameState: frameState
                ),
                cameraParallax: frameState.cameraParallax
            )
            encoder.setVertexBytes(
                &shapeUniforms,
                length: MemoryLayout<WPEShapeQuadUniforms>.stride,
                index: 1
            )
        } else if usesObjectQuad {
            var quadUniforms = executor.objectQuadUniforms(
                for: layer,
                sceneSize: executor.objectQuadSceneSize(
                    for: pass,
                    layer: layer,
                    destination: destination,
                    frameState: frameState
                ),
                cameraParallax: frameState.cameraParallax,
                sourceTexture: primary ?? destination.texture,
                cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
            if usesSkewVertex {
                var skewParams = executor.vertexSkewParams(for: pass)
                encoder.setVertexBytes(
                    &skewParams,
                    length: MemoryLayout<WPESkewParams>.stride,
                    index: 2
                )
            }
        }
    }

    private func dispatchGodraysCombine(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let usesObjectQuad = executor.usesObjectQuadGeometry(
            for: pass,
            layer: layer,
            cameraParallax: frameState.cameraParallax
        )
        encoder.setRenderPipelineState(try executor.renderPipeline(
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: "wpe_effect_godrays_combine_fragment",
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))

        let raysSlot = 0
        let albedoSlot = 1
        let baseSlot = 2
        let raysReference = pass.textureBindings[raysSlot]
            ?? pass.pass.binds[raysSlot]
            ?? pass.pass.textures[raysSlot]
            ?? pass.pass.source
        let albedoReference = pass.textureBindings[albedoSlot]
            ?? pass.pass.binds[albedoSlot]
            ?? pass.pass.textures[albedoSlot]
            ?? pass.pass.source
        let baseReference = pass.textureBindings[baseSlot]
            ?? pass.pass.binds[baseSlot]
            ?? pass.pass.textures[baseSlot]
        let raysTexture = try WPEMetalShaderInputs.resolve(
            reference: raysReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        let albedoTexture = try WPEMetalShaderInputs.resolve(
            reference: albedoReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        let baseTexture = try baseReference.map {
            try WPEMetalShaderInputs.resolve(
                reference: $0,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
        } ?? albedoTexture
        if WPESceneDebugArtifacts.shared.isEnabled {
            let destinationID = ObjectIdentifier(destination.texture)
            let raysID = ObjectIdentifier(raysTexture)
            let albedoID = ObjectIdentifier(albedoTexture)
            let baseID = ObjectIdentifier(baseTexture)
            WPESceneDebugArtifacts.shared.appendLog(
                "[godrays.combine] pass=\(pass.pass.id) "
                    + "dst=\(destination.texture.label ?? "-") \(destination.texture.width)x\(destination.texture.height) id=\(destinationID) "
                    + "rays=\(raysTexture.label ?? "-") \(raysTexture.width)x\(raysTexture.height) id=\(raysID) sameDst=\(raysTexture === destination.texture) "
                    + "albedo=\(albedoTexture.label ?? "-") \(albedoTexture.width)x\(albedoTexture.height) id=\(albedoID) sameDst=\(albedoTexture === destination.texture) "
                    + "base=\(baseTexture.label ?? "-") \(baseTexture.width)x\(baseTexture.height) id=\(baseID) sameDst=\(baseTexture === destination.texture)",
                level: .notice
            )
        }
        encoder.setFragmentTexture(raysTexture, index: raysSlot)
        encoder.setFragmentTexture(albedoTexture, index: albedoSlot)
        encoder.setFragmentTexture(baseTexture, index: baseSlot)

        let combineWithBase = baseReference == nil ? UInt32(1) : UInt32(0)
        var uniforms = WPEGodraysCombineUniforms(useBase: combineWithBase)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<WPEGodraysCombineUniforms>.stride,
            index: 0
        )

        WPESceneDebugArtifacts.shared.recordTextureBinding(
            passID: pass.pass.id,
            shader: pass.pass.shader,
            slot: 0,
            reference: raysReference,
            texture: raysTexture,
            fallbackToPrimary: false
        )
        WPESceneDebugArtifacts.shared.recordTextureBinding(
            passID: pass.pass.id,
            shader: pass.pass.shader,
            slot: 1,
            reference: albedoReference,
            texture: albedoTexture,
            fallbackToPrimary: false
        )
        WPESceneDebugArtifacts.shared.recordTextureBinding(
            passID: pass.pass.id,
            shader: pass.pass.shader,
            slot: 2,
            reference: baseReference,
            texture: baseTexture,
            fallbackToPrimary: baseReference == nil
        )

        if usesObjectQuad {
            var quadUniforms = executor.objectQuadUniforms(
                for: layer,
                sceneSize: executor.objectQuadSceneSize(
                    for: pass,
                    layer: layer,
                    destination: destination,
                    frameState: frameState
                ),
                cameraParallax: frameState.cameraParallax,
                sourceTexture: albedoTexture,
                cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
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

    private func isGroupCompositeSourceReference(_ reference: WPETextureReference, layer: WPERenderLayer) -> Bool {
        guard case .fbo(let name) = reference else {
            return false
        }
        return name == layer.groupCompositeSource
    }

    private func clearAlphaValue(for pass: WPEPreparedRenderPass) -> Float {
        comboValue(named: "CLEARALPHA", in: pass) == 1 ? 1 : 0
    }

    private func comboValue(named name: String, in pass: WPEPreparedRenderPass) -> Int {
        comboValueIfPresent(named: name, in: pass) ?? 0
    }

    private func comboValueIfPresent(named name: String, in pass: WPEPreparedRenderPass) -> Int? {
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
        return nil
    }

    private static func isGodraysCombineShader(_ shaderName: String) -> Bool {
        let normalized = shaderName.lowercased()
        return normalized == "effects/godrays_combine"
            || normalized.hasSuffix("/effects/godrays_combine")
    }

}
#endif
