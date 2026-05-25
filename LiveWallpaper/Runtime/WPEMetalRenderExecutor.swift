#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit

final class WPEMetalRenderExecutor {
    /// Phase 2A H3: every offscreen target and the on-screen swapchain share
    /// a single sRGB pixel format so render pipelines built for the offscreen
    /// pass can be reused by `present()` without re-creation, and so the
    /// rendered gamma matches the SpriteKit/CGImage fallback on the same
    /// scene fixture.
    static let outputPixelFormat: MTLPixelFormat = .rgba8Unorm_srgb

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let targetPool: WPEMetalRenderTargetPool
    private let depthCache: WPEMetalDepthStateCache
    private let pipelineCache: WPEMetalPipelineCache
    /// Invoked when the dispatcher sees a non-built-in shader. Defaults to
    /// the shipping Swift transpiler; tests inject an alternate compiler at
    /// this seam.
    let shaderCompiler: WPEShaderCompiling
    /// Phase 2D-H: memoize the per-shader compile across frames so we
    /// don't re-translate every draw call.
    private var translatedShaderCache: [String: WPEShaderCompileResult] = [:]
    /// Phase 2D-H: cache MTLRenderPipelineState built from translated
    /// shaders. Library + blend + format set is the key.
    private var translatedPipelineCache: [TranslatedPipelineKey: MTLRenderPipelineState] = [:]

    private struct TranslatedPipelineKey: Hashable {
        let libraryID: ObjectIdentifier
        let fragmentName: String
        let blendMode: String
        let colorPixelFormat: UInt
        let depthPixelFormat: UInt
    }

    init(device: MTLDevice, shaderCompiler: WPEShaderCompiling? = nil) throws {
        guard let queue = device.makeCommandQueue() else {
            throw WPEMetalRenderExecutorError.commandQueueUnavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw WPEMetalRenderExecutorError.libraryUnavailable
        }
        self.device = device
        commandQueue = queue
        self.targetPool = WPEMetalRenderTargetPool(device: device)
        self.depthCache = WPEMetalDepthStateCache(device: device)
        self.pipelineCache = WPEMetalPipelineCache(device: device, library: library)
        self.shaderCompiler = shaderCompiler ?? Self.preferredCompiler(device: device)
    }

    private static func preferredCompiler(device: MTLDevice) -> any WPEShaderCompiling {
        // The Swift transpiler is the only Metal-side translator we ship.
        // Shaders it can't handle bubble up as
        // `WPEMetalRenderExecutorError.shaderTranslatorUnavailable`, which
        // `SceneWallpaperSession` then redirects to the WebGL renderer
        // through the scene-level fallback.
        WPESwiftShaderCompiler(device: device)
    }

    /// Phase 2E: lets `WPEMetalSceneRenderer` hand the executor's MTLDevice
    /// to `WPEVideoTextureSource` (which needs it to build a
    /// `CVMetalTextureCache`) without exposing the device publicly.
    var textureSourceDevice: MTLDevice {
        device
    }

    func releaseTransientResources() {
        targetPool.releaseAll()
    }

    func render(
        pipeline: WPEPreparedRenderPipeline,
        size: CGSize,
        textures: [String: MTLTexture],
        runtimeUniforms: WPEMetalRuntimeUniforms = .zero,
        cameraUniforms: WPEMetalCameraUniforms = .identity
    ) throws -> MTLTexture {
        let preparedPipeline = pipeline.addingMetalRuntimeUniforms(runtimeUniforms, camera: cameraUniforms)
        let output = try makeOutputTexture(size: size)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        targetPool.prepare(pipeline: preparedPipeline)
        var frameState = WPEMetalFrameState(output: output, sceneSize: size)
        var didEncode = false

        for layer in preparedPipeline.layers {
            if layer.passes.isEmpty {
                try encodeCopy(
                    reference: .image(layer.graphLayer.imagePath),
                    target: .scene,
                    layer: layer.graphLayer,
                    runtimeUniforms: runtimeUniforms,
                    textures: textures,
                    commandBuffer: commandBuffer,
                    frameState: &frameState
                )
                didEncode = true
                continue
            }
            for pass in layer.passes {
                try encode(
                    pass: pass,
                    layer: layer.graphLayer,
                    textures: textures,
                    commandBuffer: commandBuffer,
                    frameState: &frameState
                )
                didEncode = true
            }
        }

        guard didEncode else {
            throw WPEMetalRenderExecutorError.noRenderablePasses
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status == .error {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        return output
    }

    /// Phase 2D-L: render every alive particle system on top of the supplied output texture.
    func drawParticles(
        systems: [WPEParticleSystem],
        texturesByMaterial: [ObjectIdentifier: MTLTexture],
        sceneSize: CGSize,
        output: MTLTexture
    ) throws {
        let alive = systems.filter { $0.liveInstanceCount > 0 }
        guard !alive.isEmpty else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        var projection = WPEParticleProjection(
            sceneSize: SIMD4<Float>(
                Float(max(sceneSize.width, 1)),
                Float(max(sceneSize.height, 1)),
                0, 0
            )
        )

        for system in alive {
            // A system whose texture failed to load was already filtered
            // out at scene-load time (see loadParticleSystems). Skip here
            // defensively so a stale Metal texture-slot binding from a
            // prior system can never leak into the current draw.
            guard let texture = texturesByMaterial[ObjectIdentifier(system)] else {
                continue
            }
            let pipelineState = try particlePipelineState(
                colorPixelFormat: output.pixelFormat,
                blendMode: system.blendMode
            )
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(system.instanceBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&projection, length: MemoryLayout<WPEParticleProjection>.stride, index: 2)
            var sprite = WPEParticleSpriteParams(grid: SIMD4<Float>(
                Float(system.spriteSheet?.cols ?? 1),
                Float(system.spriteSheet?.rows ?? 1),
                Float(system.spriteSheet?.frameCount ?? 1),
                (system.spriteSheet?.isAlphaMask ?? false) ? 1 : 0
            ))
            encoder.setVertexBytes(&sprite, length: MemoryLayout<WPEParticleSpriteParams>.stride, index: 3)
            encoder.setFragmentBytes(&sprite, length: MemoryLayout<WPEParticleSpriteParams>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: system.liveInstanceCount
            )
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Mirrors `WPEParticleSpriteParams` in `WPEMetalBuiltins.metal` —
    /// `grid.xy = (cols, rows)`, `grid.z = frameCount` (loop modulo),
    /// `grid.w = 1` flags an r8 alpha-mask atlas (fog particles) so the
    /// fragment shader pulls colour from the per-particle tint and uses
    /// the texture sample only as the opacity.
    struct WPEParticleSpriteParams {
        var grid: SIMD4<Float>
    }

    /// Phase 2D-N: composite a list of pre-rasterized text overlays on top of the supplied output texture.
    func drawTextOverlays(
        overlays: [WPETextOverlayDraw],
        sceneSize: CGSize,
        output: MTLTexture
    ) throws {
        guard !overlays.isEmpty else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        let state = try textOverlayPipelineState(colorPixelFormat: output.pixelFormat)
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
                    0, 0
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
        commandBuffer.waitUntilCompleted()
    }

    private var textOverlayPipelineCache: [UInt: MTLRenderPipelineState] = [:]

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

    private struct ParticlePipelineKey: Hashable {
        let pixelFormat: UInt
        let blendMode: WPEParticleBlendMode
    }

    private var particlePipelineCache: [ParticlePipelineKey: MTLRenderPipelineState] = [:]

    private func particlePipelineState(
        colorPixelFormat: MTLPixelFormat,
        blendMode: WPEParticleBlendMode
    ) throws -> MTLRenderPipelineState {
        let key = ParticlePipelineKey(pixelFormat: colorPixelFormat.rawValue, blendMode: blendMode)
        if let cached = particlePipelineCache[key] {
            return cached
        }
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "wpe_particle_vertex"),
              let fragment = library.makeFunction(name: "wpe_particle_instanced_fragment") else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_particle_instanced_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let attachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_particle_instanced_fragment")
        }
        attachment.pixelFormat = colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        // Fragment shader outputs straight (non-premultiplied) alpha. WPE
        // material `blending` strings map to the three classic factor
        // combos — anything else falls back to translucent at parse time.
        switch blendMode {
        case .normal:
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .zero
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .zero
        case .translucent:
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationAlphaBlendFactor = .one
        }
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        particlePipelineCache[key] = state
        return state
    }

    @MainActor
    func present(texture source: MTLTexture, in view: MTKView) throws -> Bool {
        guard let drawable = view.currentDrawable else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.setRenderPipelineState(try renderPipeline(
            fragmentName: "wpe_copy_fragment",
            blendMode: "disabled",
            colorPixelFormat: drawable.texture.pixelFormat
        ))
        encoder.setFragmentTexture(source, index: 0)
        var uniforms = WPECopyUniforms(uvOffset: SIMD2<Float>(0, 0))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPECopyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    private func encode(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        let targetID = WPEMetalTargetID(target: pass.pass.target)
        let previousTextureForTarget = frameState.latestTexture(for: targetID)
        let readsCurrentTarget = passReadsCurrentTarget(pass, targetID: targetID)
        let destination = try targetTexture(
            for: pass.pass.target,
            layer: layer,
            frameState: &frameState,
            avoiding: readsCurrentTarget ? previousTextureForTarget : nil
        )

        try snapshotFullFrameBufferIfAliasingScene(
            pass: pass,
            destinationTexture: destination.texture,
            targetID: targetID,
            layer: layer,
            commandBuffer: commandBuffer,
            frameState: &frameState
        )

        if readsCurrentTarget,
           let previousTextureForTarget,
           ObjectIdentifier(previousTextureForTarget) != ObjectIdentifier(destination.texture),
           !frameState.hasInitialized(destination.texture) {
            try copyTexture(
                previousTextureForTarget,
                to: destination.texture,
                commandBuffer: commandBuffer
            )
            frameState.markInitialized(destination.texture)
        }

        let needsDepth = depthCache.needsAttachment(for: pass)

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        descriptor.colorAttachments[0].loadAction = frameState.hasInitialized(destination.texture) ? .load : .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if needsDepth {
            let depth = try depthCache.attachmentTexture(for: destination, frameState: &frameState)
            descriptor.depthAttachment.texture = depth
            descriptor.depthAttachment.loadAction = frameState.hasInitialized(destination.texture) ? .load : .clear
            descriptor.depthAttachment.storeAction = .store
            descriptor.depthAttachment.clearDepth = 1
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        defer { encoder.endEncoding() }

        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(WPEMetalPipelineCache.cullMode(for: pass.pass.cullMode))
        encoder.setDepthStencilState(depthCache.stencilState(
            depthTest: pass.pass.depthTest,
            depthWrite: pass.pass.depthWrite
        ))

        let dispatcher = WPEMetalShaderDispatcher(executor: self)
        try dispatcher.dispatch(
            pass: pass,
            layer: layer,
            destination: destination,
            textures: textures,
            frameState: frameState,
            encoder: encoder,
            depthPixelFormat: needsDepth ? .depth32Float : .invalid
        )

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        frameState.registerWrite(texture: destination.texture, targetID: destination.id)
    }

    /// Breaks the `_rt_*` scene-alias hazard.
    private func snapshotFullFrameBufferIfAliasingScene(
        pass: WPEPreparedRenderPass,
        destinationTexture: MTLTexture,
        targetID: WPEMetalTargetID,
        layer: WPERenderLayer,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        guard targetID == .scene else { return }
        let aliases = textureReferences(for: pass).compactMap { reference -> String? in
            guard case .fbo(let name) = reference,
                  WPEMetalShaderInputs.isSceneAliasName(name),
                  frameState.latestNamedTextures[name] == nil else {
                return nil
            }
            return name
        }
        guard let alias = aliases.first else { return }
        let snapshot = try targetPool.texture(
            for: .fbo(name: alias),
            layer: layer,
            sceneSize: frameState.sceneSize,
            avoiding: destinationTexture
        )
        if let source = frameState.latestSceneTexture {
            try copyTexture(source, to: snapshot, commandBuffer: commandBuffer)
            frameState.markInitialized(snapshot)
        }
        frameState.latestNamedTextures[alias] = snapshot
    }

    /// Phase 2C audit fix: blit-copies a prior physical texture into the pool's secondary slot so ping-pong renders that blend or depth-test have a defined source to load.
    private func copyTexture(
        _ source: MTLTexture,
        to destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: destination.width, height: destination.height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin()
        )
        blit.endEncoding()
    }

    private func encodeCopy(
        reference: WPETextureReference,
        target: WPERenderTarget,
        layer: WPERenderLayer,
        runtimeUniforms: WPEMetalRuntimeUniforms,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        let targetID = WPEMetalTargetID(target: target)
        let previousTextureForTarget = frameState.latestTexture(for: targetID)
        let readsCurrentTarget = reference == .previous
        let destination = try targetTexture(
            for: target,
            layer: layer,
            frameState: &frameState,
            avoiding: readsCurrentTarget ? previousTextureForTarget : nil
        )

        if readsCurrentTarget,
           let previousTextureForTarget,
           ObjectIdentifier(previousTextureForTarget) != ObjectIdentifier(destination.texture),
           !frameState.hasInitialized(destination.texture) {
            try copyTexture(
                previousTextureForTarget,
                to: destination.texture,
                commandBuffer: commandBuffer
            )
            frameState.markInitialized(destination.texture)
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        descriptor.colorAttachments[0].loadAction = frameState.hasInitialized(destination.texture) ? .load : .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        defer { encoder.endEncoding() }

        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)

        encoder.setRenderPipelineState(try renderPipeline(
            fragmentName: "wpe_copy_fragment",
            blendMode: "disabled",
            colorPixelFormat: destination.texture.pixelFormat
        ))
        encoder.setFragmentTexture(
            try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            ),
            index: 0
        )
        var uniforms = WPECopyUniforms(
            uvOffset: WPEMetalShaderInputs.parallaxUVOffset(
                pointerPosition: runtimeUniforms.pointerPosition,
                parallaxDepth: layer.parallaxDepth
            )
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPECopyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        frameState.registerWrite(texture: destination.texture, targetID: destination.id)
    }

    /// Thin delegate so call sites — including `WPEMetalShaderDispatcher` across files — keep the same call shape after the pipeline cache became a separate type.
    func renderPipeline(
        fragmentName: String,
        blendMode: String = "disabled",
        colorPixelFormat: MTLPixelFormat = WPEMetalRenderExecutor.outputPixelFormat,
        depthPixelFormat: MTLPixelFormat = .invalid
    ) throws -> MTLRenderPipelineState {
        try pipelineCache.pipelineState(
            fragmentName: fragmentName,
            blendMode: blendMode,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat
        )
    }

    private func makeOutputTexture(size: CGSize) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.outputPixelFormat,
            width: max(Int(size.width), 1),
            height: max(Int(size.height), 1),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE Metal executor output"
        return texture
    }

    private func targetTexture(
        for target: WPERenderTarget,
        layer: WPERenderLayer,
        frameState: inout WPEMetalFrameState,
        avoiding textureToAvoid: MTLTexture? = nil
    ) throws -> (id: WPEMetalTargetID, texture: MTLTexture) {
        let targetID = WPEMetalTargetID(target: target)
        switch target {
        case .scene:
            return (targetID, frameState.output)
        case .fbo, .layerComposite:
            let texture = try targetPool.texture(
                for: target,
                layer: layer,
                sceneSize: frameState.sceneSize,
                avoiding: textureToAvoid
            )
            return (targetID, texture)
        }
    }

    /// Phase 2D-E: shared dispatch path for single-input effect built-ins (opacity, scroll, pulse, iris, waterwaves).
    func dispatchSingleSampleEffect<U: BitwiseCopyable>(
        fragmentName: String,
        pass: WPEPreparedRenderPass,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat,
        uniforms: U
    ) throws {
        encoder.setRenderPipelineState(try renderPipeline(
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
        var local = uniforms
        encoder.setFragmentBytes(&local, length: MemoryLayout<U>.stride, index: 0)
    }

    /// Phase 2D-D: pack scene uniforms for the genericimage* built-ins.
    func genericImageUniforms(for pass: WPEPreparedRenderPass, hasMask: Bool) -> WPEGenericImageUniforms {
        WPEGenericImageUniforms(
            color: WPEMetalShaderInputs.colorVector(for: pass),
            alphaMaskUV: SIMD4<Float>(
                WPEMetalShaderInputs.floatScalar(named: ["g_Alpha", "u_Alpha", "alpha"], in: pass, default: 1),
                WPEMetalShaderInputs.floatScalar(named: ["g_Brightness", "u_Brightness", "brightness"], in: pass, default: 1),
                hasMask ? 1 : 0,
                0
            )
        )
    }

    /// Phase 2D-D: per-particle uniform pack.
    func genericParticleUniforms(for pass: WPEPreparedRenderPass) -> WPEGenericParticleUniforms {
        WPEGenericParticleUniforms(
            color: WPEMetalShaderInputs.colorVector(for: pass),
            sizeAndAge: SIMD4<Float>(
                WPEMetalShaderInputs.floatScalar(named: ["g_Alpha", "u_Alpha", "alpha"], in: pass, default: 1),
                WPEMetalShaderInputs.floatScalar(named: ["g_Brightness", "u_Brightness", "brightness"], in: pass, default: 1),
                0,
                0
            )
        )
    }

    private func passReadsCurrentTarget(_ pass: WPEPreparedRenderPass, targetID: WPEMetalTargetID) -> Bool {
        textureReferences(for: pass).contains { reference in
            switch (reference, targetID) {
            case (.previous, _):
                return true
            case (.fbo(let name), .named(let targetName)):
                return name == targetName
            default:
                return false
            }
        }
    }

    private func textureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
        var references: [WPETextureReference] = [pass.pass.source]
        references.append(contentsOf: pass.pass.textures.values)
        references.append(contentsOf: pass.pass.binds.values)
        references.append(contentsOf: pass.textureBindings.values)
        return references
    }

    /// Build (or fetch from cache) an `MTLRenderPipelineState` for a translated shader's fragment function.
    func translatedPipelineState(
        for result: WPEShaderCompileResult,
        blendMode: String,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let key = TranslatedPipelineKey(
            libraryID: ObjectIdentifier(result.library),
            fragmentName: result.fragmentFunctionName,
            blendMode: blendMode.lowercased(),
            colorPixelFormat: colorPixelFormat.rawValue,
            depthPixelFormat: depthPixelFormat.rawValue
        )
        if let cached = translatedPipelineCache[key] {
            return cached
        }
        guard let vertex = result.library.makeFunction(name: result.vertexFunctionName)
            ?? device.makeDefaultLibrary()?.makeFunction(name: result.vertexFunctionName),
              let fragment = result.library.makeFunction(name: result.fragmentFunctionName) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(result.fragmentFunctionName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let colorAttachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(result.fragmentFunctionName)
        }
        colorAttachment.pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        Self.applyBlendMode(blendMode.lowercased(), to: colorAttachment)
        let state: MTLRenderPipelineState
        do {
            state = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw WPEMetalRenderExecutorError.pipelineStateBuildFailed(
                name: result.fragmentFunctionName,
                detail: error.localizedDescription
            )
        }
        translatedPipelineCache[key] = state
        return state
    }

    /// Phase 2D-H: pack a runtime uniform buffer matching the layout the transpiler emitted (every uniform takes 1-4 float4 slots).
    func packTranslatedUniforms(
        for pass: WPEPreparedRenderPass,
        layout: [WPEUniformSlot]
    ) -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: WPEShaderTranspiler.uniformSlotMaximum)
        for u in layout {
            let value = pass.uniformValues[u.name] ?? pass.pass.constants[u.name]
            if let length = u.arrayLength {
                let raw = Self.vectorValue(value, count: length)
                for i in 0..<length {
                    let v = raw.indices.contains(i) ? raw[i] : 0
                    let slotIndex = u.slot + i
                    guard slotIndex < slots.count else { break }
                    switch u.glslType {
                    case "vec2":
                        let stride = 2
                        slots[slotIndex] = SIMD4<Float>(
                            raw.indices.contains(i * stride) ? raw[i * stride] : 0,
                            raw.indices.contains(i * stride + 1) ? raw[i * stride + 1] : 0,
                            0, 0
                        )
                    case "vec3":
                        let stride = 3
                        slots[slotIndex] = SIMD4<Float>(
                            raw.indices.contains(i * stride) ? raw[i * stride] : 0,
                            raw.indices.contains(i * stride + 1) ? raw[i * stride + 1] : 0,
                            raw.indices.contains(i * stride + 2) ? raw[i * stride + 2] : 0,
                            0
                        )
                    case "vec4":
                        let stride = 4
                        slots[slotIndex] = SIMD4<Float>(
                            raw.indices.contains(i * stride) ? raw[i * stride] : 0,
                            raw.indices.contains(i * stride + 1) ? raw[i * stride + 1] : 0,
                            raw.indices.contains(i * stride + 2) ? raw[i * stride + 2] : 0,
                            raw.indices.contains(i * stride + 3) ? raw[i * stride + 3] : 0
                        )
                    default:
                        slots[slotIndex].x = v
                    }
                }
                continue
            }
            switch u.glslType {
            case "float", "int", "bool":
                slots[u.slot].x = Self.scalarValue(value, default: 0)
            case "vec2":
                let v = Self.vectorValue(value, count: 2)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], 0, 0)
            case "vec3":
                let v = Self.vectorValue(value, count: 3)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], 0)
            case "vec4":
                let v = Self.vectorValue(value, count: 4)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], v[3])
            case "mat2":
                let v = Self.vectorValue(value, count: 4)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], 0, 0)
                slots[u.slot + 1] = SIMD4<Float>(v[2], v[3], 0, 0)
            case "mat3":
                let v = Self.vectorValue(value, count: 9)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], 0)
                slots[u.slot + 1] = SIMD4<Float>(v[3], v[4], v[5], 0)
                slots[u.slot + 2] = SIMD4<Float>(v[6], v[7], v[8], 0)
            case "mat4":
                let v = Self.vectorValue(value, count: 16)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], v[3])
                slots[u.slot + 1] = SIMD4<Float>(v[4], v[5], v[6], v[7])
                slots[u.slot + 2] = SIMD4<Float>(v[8], v[9], v[10], v[11])
                slots[u.slot + 3] = SIMD4<Float>(v[12], v[13], v[14], v[15])
            default:
                slots[u.slot].x = Self.scalarValue(value, default: 0)
            }
        }
        return slots
    }

    private static func scalarValue(_ value: WPESceneShaderConstantValue?, default fallback: Float) -> Float {
        switch value {
        case .number(let n): return Float(n)
        case .vector(let v): return Float(v.first ?? Double(fallback))
        case .bool(let b):   return b ? 1 : 0
        case .string(let s): return Float(s) ?? fallback
        case nil:            return fallback
        }
    }

    private static func vectorValue(_ value: WPESceneShaderConstantValue?, count: Int) -> [Float] {
        switch value {
        case .vector(let v):
            var out = v.map(Float.init)
            while out.count < count { out.append(0) }
            return out
        case .number(let n):
            var out = [Float](repeating: 0, count: count)
            out[0] = Float(n)
            return out
        default:
            return [Float](repeating: 0, count: count)
        }
    }

    /// Mirrors WPEMetalPipelineCache.applyBlendMode so the translated pipeline path uses the same blend arithmetic as built-ins.
    private static func applyBlendMode(_ mode: String, to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        switch mode {
        case "disabled":
            attachment.isBlendingEnabled = false
        case "additive":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        case "multiply":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .destinationColor
            attachment.destinationRGBBlendFactor = .zero
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one
        case "translucent":
            fallthrough
        default:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
    }

    /// Run the WPE preprocessor + the configured `WPEShaderCompiling` over the given prepared pass.
    func compileCustomShader(
        for pass: WPEPreparedRenderPass
    ) throws -> WPEShaderCompileResult {
        guard let program = pass.shader else {
            throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
        }
        let processor = WPEShaderPreprocessor { _, _ in
            nil
        }
        let request: WPEShaderCompileRequest
        do {
            request = try processor.process(
                shaderName: program.name,
                vertexSource: program.vertexSource,
                fragmentSource: program.fragmentSource,
                comboValues: pass.comboValues,
                materialTextureBindings: Dictionary(
                    uniqueKeysWithValues: pass.textureBindings.compactMap { (slot, ref) -> (Int, String)? in
                        switch ref {
                        case .image(let p), .asset(let p): return (slot, p)
                        case .fbo(let n): return (slot, n)
                        case .previous: return nil
                        }
                    }
                )
            )
        } catch let error as WPEShaderCompilerError {
            WPESceneDebugArtifacts.shared.recordShaderFailure(
                shaderName: program.name,
                originalVertex: program.vertexSource,
                processedVertex: nil,
                originalFragment: program.fragmentSource,
                processedFragment: nil,
                translatedMSL: nil,
                errorText: "preprocess failed: \(String(describing: error))"
            )
            throw WPEMetalRenderExecutorError.shaderTranslatorUnavailable(
                name: program.name,
                reason: String(describing: error)
            )
        }
        if let cached = translatedShaderCache[request.sourceHash] {
            return cached
        }
        do {
            let result = try shaderCompiler.compile(request)
            translatedShaderCache[request.sourceHash] = result
            return result
        } catch let error as WPEShaderCompilerError {
            switch error {
            case .backendUnavailable(let reason),
                 .glslPreprocessFailed(let reason),
                 .translationFailed(let reason),
                 .mslLibraryFailed(let reason):
                // The compiler already dumped processed sources; tack on the
                // pre-preprocess originals so a maintainer can diff to see
                // exactly which fixup turned the source unparseable.
                WPESceneDebugArtifacts.shared.recordShaderFailure(
                    shaderName: program.name,
                    originalVertex: program.vertexSource,
                    processedVertex: request.processedVertexSource,
                    originalFragment: program.fragmentSource,
                    processedFragment: request.processedFragmentSource,
                    translatedMSL: nil,
                    errorText: "compile failed: \(reason)"
                )
                throw WPEMetalRenderExecutorError.shaderTranslatorUnavailable(
                    name: program.name,
                    reason: reason
                )
            }
        }
    }
}
#endif
