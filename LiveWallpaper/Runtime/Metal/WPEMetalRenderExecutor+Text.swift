#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

extension WPEMetalRenderExecutor {
    /// Composites pre-rasterized text overlays onto the supplied output texture.
    func drawTextOverlays(
        overlays: [WPETextOverlayDraw],
        sceneSize: CGSize,
        output: MTLTexture
    ) throws {
        guard !overlays.isEmpty else { return }
        // Resolve the pipeline (can throw) BEFORE opening the encoder, so a
        // failure never leaks an encoder without endEncoding (Metal asserts
        // "Command encoder released without endEncoding").
        let state = try textOverlayPipelineState(colorPixelFormat: output.pixelFormat)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "textOverlay")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.setRenderPipelineState(state)

        for overlay in overlays {
            var u = WPETextOverlayUniforms(
                centerAndSize: SIMD4<Float>(
                    Float(overlay.centerInScenePixels.x),
                    Float(overlay.centerInScenePixels.y),
                    Float(overlay.sizeInScenePixels.width),
                    Float(overlay.sizeInScenePixels.height)
                ),
                sceneSize: SIMD4<Float>(
                    Float(max(sceneSize.width, 1)),
                    Float(max(sceneSize.height, 1)),
                    overlay.rotation, 0
                ),
                color: SIMD4<Float>(
                    overlay.tint.x,
                    overlay.tint.y,
                    overlay.tint.z,
                    overlay.alpha
                )
            )
            encoder.setFragmentTexture(overlay.texture, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<WPETextOverlayUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<WPETextOverlayUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        // Same queue as the scene render, so this composites after it GPU-side
        // without a CPU stall; only block when a read-back needs finished pixels.
        if synchronizeFrameCompletion { commandBuffer.waitUntilCompleted() }
    }

    /// Draw GPU MSDF text: compile the translated `font.frag` (cached per combo
    /// set), bind per-page glyph quads + atlas texture, pack the font material
    /// uniforms by slot, and composite with premultiplied alpha onto `output`.
    func drawMSDFText(
        payloads: [WPEMSDFTextDrawPayload],
        sceneSize: CGSize,
        output: MTLTexture
    ) throws {
        guard !payloads.isEmpty else { return }

        // Resolve everything that can THROW (white texture, font.frag compile,
        // pipeline state) BEFORE opening the render encoder. A failure here (e.g.
        // a font.frag combo that won't translate) then throws with no encoder
        // open, so the scene renderer can catch it and fall back to CoreText.
        // Doing these `try`s after makeRenderCommandEncoder would dealloc the
        // encoder without endEncoding → Metal asserts
        // ("Command encoder released without endEncoding") and crashes.
        let whiteTexture = try msdfWhiteTexture()
        let prepared: [(state: MTLRenderPipelineState, result: WPEShaderCompileResult, payload: WPEMSDFTextDrawPayload)] =
            try payloads.map { payload in
                let result = try compileMSDFFontShader(payload.shaderRequest)
                let state = try msdfTextPipelineState(for: result, colorPixelFormat: output.pixelFormat)
                return (state: state, result: result, payload: payload)
            }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "textMSDF")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        var sceneSizeValue = SIMD2<Float>(
            Float(max(sceneSize.width, 1)),
            Float(max(sceneSize.height, 1))
        )
        // From here on there are NO throwing calls until endEncoding().
        for item in prepared {
            encoder.setRenderPipelineState(item.state)
            encoder.setVertexBytes(&sceneSizeValue, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

            for page in item.payload.pages {
                encoder.setVertexBuffer(page.vertexBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(page.texture, index: 0)
                encoder.setFragmentTexture(whiteTexture, index: 1)
                let slots = packTranslatedUniforms(
                    values: item.payload.uniforms,
                    layout: item.result.uniformLayout,
                    texturesBySlot: [0: page.texture, 1: whiteTexture],
                    destinationTexture: output
                )
                bindTranslatedUniformSlots(slots, to: encoder)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: page.vertexCount)
            }
        }
        encoder.endEncoding()
        commandBuffer.commit()
        // Same queue as the scene render, so this composites after it GPU-side
        // without a CPU stall; only block when a read-back needs finished pixels.
        if synchronizeFrameCompletion { commandBuffer.waitUntilCompleted() }
    }

    private func compileMSDFFontShader(_ request: WPEShaderCompileRequest) throws -> WPEShaderCompileResult {
        if let cached = translatedShaderCache[request.translationCacheKey] {
            return cached
        }
        let result = try shaderCompiler.compile(request)
        translatedShaderCache[request.translationCacheKey] = result
        return result
    }

    private func msdfTextPipelineState(
        for result: WPEShaderCompileResult,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let key = MSDFTextPipelineKey(
            libraryID: ObjectIdentifier(result.library),
            colorPixelFormat: colorPixelFormat.rawValue
        )
        if let cached = msdfTextPipelineCache[key] {
            return cached
        }
        guard let vertex = device.makeDefaultLibrary()?.makeFunction(name: "wpe_msdf_text_vertex"),
              let fragment = result.library.makeFunction(name: result.fragmentFunctionName) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(result.fragmentFunctionName)
        }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertex
        pipelineDescriptor.fragmentFunction = fragment
        guard let attachment = pipelineDescriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(result.fragmentFunctionName)
        }
        attachment.pixelFormat = colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        // font.frag returns STRAIGHT (non-premultiplied) alpha — vec4(rgb, a) —
        // so source RGB must be scaled by sourceAlpha. Using .one (premultiplied)
        // over-contributed RGB and haloed semi-transparent text / AA edges.
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let state = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        msdfTextPipelineCache[key] = state
        return state
    }

    private func msdfWhiteTexture() throws -> MTLTexture {
        if let msdfNeutralWhiteTexture { return msdfNeutralWhiteTexture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_msdf_text_white_texture")
        }
        texture.label = "WPE MSDF neutral white"
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
        var pixel: UInt32 = 0xFFFF_FFFF
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4
        )
        msdfNeutralWhiteTexture = texture
        return texture
    }

    private func textOverlayPipelineState(colorPixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = textOverlayPipelineCache[colorPixelFormat.rawValue] {
            return cached
        }
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "wpe_text_overlay_vertex"),
              let fragment = library.makeFunction(name: "wpe_text_overlay_fragment") else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_text_overlay_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let attachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_text_overlay_fragment")
        }
        attachment.pixelFormat = colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        textOverlayPipelineCache[colorPixelFormat.rawValue] = state
        return state
    }

}
#endif
