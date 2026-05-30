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

    /// Debug bisect flag: when `defaults write Taijia.LiveWallpaper
    /// WPEMetalBypassEffects -bool YES` is in effect (and the binary is
    /// a DEBUG build) every image layer skips its material/effect/command
    /// passes and blits the first pass's resolved source texture to scene.
    /// Used to confirm Metal's upload+present chain reaches the screen
    /// before the effect shader chain is exercised. Always false in
    /// Release builds.
    static var bypassEffectsForDebug: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "WPEMetalBypassEffects")
        #else
        return false
        #endif
    }

    /// Mirrors the slot-0 precedence used by
    /// `WPEMetalSceneRenderer.requiredTextureReferences(for:)`: prefer the
    /// per-pass binding override, then the pass's `textures[0]`, then the
    /// raw graph source. We use this to look up the layer's resolved
    /// background image in the bypass path so the blit copies the asset
    /// the renderer actually preloaded — not the unresolved model JSON
    /// path that `WPERenderLayer.imagePath` carries.
    static func bypassSourceReference(for layer: WPEPreparedRenderLayer) -> WPETextureReference? {
        guard let firstPass = layer.passes.first else { return nil }
        return firstPass.textureBindings[0]
            ?? firstPass.pass.textures[0]
            ?? firstPass.pass.source
    }

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
    private var previousFrameHistory: PreviousFrameHistory?

    private struct PreviousFrameHistory {
        let sceneSize: CGSize
        let sceneTexture: MTLTexture?
        let namedTextures: [String: MTLTexture]
    }

    private struct TranslatedPipelineKey: Hashable {
        let libraryID: ObjectIdentifier
        let vertexName: String
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
        // automatic scene sessions may use as the WebGL fallback signal.
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
        previousFrameHistory = nil
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

        let reusableHistory: PreviousFrameHistory?
        if let history = previousFrameHistory, history.sceneSize == size {
            reusableHistory = history
        } else {
            reusableHistory = nil
            previousFrameHistory = nil
        }

        targetPool.prepare(pipeline: preparedPipeline)
        var frameState = WPEMetalFrameState(
            output: output,
            sceneSize: size,
            previousSceneTexture: reusableHistory?.sceneTexture,
            previousNamedTextures: reusableHistory?.namedTextures ?? [:]
        )
        var didEncode = false
        let bypassEffects = Self.bypassEffectsForDebug

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
            if bypassEffects, let firstSource = Self.bypassSourceReference(for: layer) {
                // Debug bisect: skip every material/effect/command pass and
                // blit the first pass's resolved source (the background
                // image) straight to scene. Lets us prove the upload +
                // present chain works at the layer's native resolution
                // before the effect shaders join the mix.
                try encodeCopy(
                    reference: firstSource,
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
                    puppetModel: layer.puppetModel,
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
        previousFrameHistory = PreviousFrameHistory(
            sceneSize: size,
            sceneTexture: frameState.latestSceneTexture,
            namedTextures: frameState.latestNamedTextures.filter { entry in
                !WPEMetalShaderInputs.isSceneAliasName(entry.key)
            }
        )
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
        guard let drawable = view.currentDrawable else {
            #if DEBUG
            Logger.warning(
                "[present] view.currentDrawable=nil — source=\(source.width)x\(source.height) view.bounds=\(view.bounds) drawableSize=\(view.drawableSize)",
                category: .wpeRender
            )
            #endif
            return false
        }
        #if DEBUG
        Logger.debug(
            "[present] source=\(source.width)x\(source.height) fmt=\(source.pixelFormat.rawValue) → drawable=\(drawable.texture.width)x\(drawable.texture.height) fmt=\(drawable.texture.pixelFormat.rawValue) view.bounds=\(view.bounds) view.frame=\(view.frame) drawableSize=\(view.drawableSize)",
            category: .wpeRender
        )
        #endif
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
        #if DEBUG
        commandBuffer.addCompletedHandler { [weak source] cb in
            if cb.status == .error {
                Logger.warning(
                    "[present] commandBuffer ERROR after present: \(cb.error?.localizedDescription ?? "unknown")",
                    category: .wpeRender
                )
            } else if let source {
                Logger.debug(
                    "[present] commandBuffer completed status=\(cb.status.rawValue) source.label=\(source.label ?? "nil")",
                    category: .wpeRender
                )
            }
        }
        #endif
        commandBuffer.commit()
        return true
    }

    private func clearColor(for targetID: WPEMetalTargetID) -> MTLClearColor {
        switch targetID {
        case .scene:
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        case .named:
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
    }

    /// Whether a pass should `.load` the existing attachment contents instead of
    /// `.clear`ing. A ping-pong composite's physical texture is reused across
    /// passes, so a later source-over pass writing the SAME named target would
    /// otherwise blend over an earlier logical pass's stale result (the
    /// hair/staff "double displacement" ghost). Only load when the contents are
    /// genuinely needed: a self/previous-target read (feedback), the scene
    /// framebuffer (layer compositing), or an accumulation blend.
    private func shouldLoadExistingAttachment(
        for pass: WPEPreparedRenderPass,
        targetID: WPEMetalTargetID,
        destinationTexture: MTLTexture,
        readsCurrentTarget: Bool,
        frameState: WPEMetalFrameState
    ) -> Bool {
        guard frameState.hasInitialized(destinationTexture) else {
            return false
        }
        if readsCurrentTarget {
            return true
        }
        if case .scene = targetID {
            return true
        }
        return blendModeRequiresExistingDestination(pass.pass.blending)
    }

    private func blendModeRequiresExistingDestination(_ blendMode: String) -> Bool {
        let normalized = blendMode
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch normalized {
        case "add",
             "additive",
             "darken",
             "lighten",
             "multiply",
             "negative",
             "oneone",
             "oneoneone",
             "subtract",
             "subtractive":
            return true
        default:
            return false
        }
    }

    private func encode(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        puppetModel: WPEPuppetModel?,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        let targetID = WPEMetalTargetID(target: pass.pass.target)
        let initialPreviousTextureForTarget = frameState.latestTexture(for: targetID)
        let readsCurrentTarget = passReadsCurrentTarget(pass, targetID: targetID)
        let destination = try targetTexture(
            for: pass.pass.target,
            layer: layer,
            frameState: &frameState,
            avoiding: readsCurrentTarget ? initialPreviousTextureForTarget : nil
        )

        try snapshotFullFrameBufferIfAliasingScene(
            pass: pass,
            destinationTexture: destination.texture,
            targetID: targetID,
            layer: layer,
            commandBuffer: commandBuffer,
            frameState: &frameState
        )

        let previousTextureForTarget: MTLTexture?
        if readsCurrentTarget {
            previousTextureForTarget = try previousTextureForRead(
                targetID: targetID,
                matching: destination.texture,
                commandBuffer: commandBuffer,
                frameState: &frameState
            )
        } else {
            previousTextureForTarget = initialPreviousTextureForTarget
        }

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

        let shouldLoadExistingAttachment = shouldLoadExistingAttachment(
            for: pass,
            targetID: targetID,
            destinationTexture: destination.texture,
            readsCurrentTarget: readsCurrentTarget,
            frameState: frameState
        )

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        descriptor.colorAttachments[0].loadAction = shouldLoadExistingAttachment ? .load : .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor(for: targetID)

        if needsDepth {
            let depth = try depthCache.attachmentTexture(for: destination, frameState: &frameState)
            descriptor.depthAttachment.texture = depth
            descriptor.depthAttachment.loadAction = shouldLoadExistingAttachment ? .load : .clear
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

        let drewPuppetMesh = try encodePuppetMaterialPassIfNeeded(
            pass: pass,
            layer: layer,
            puppetModel: puppetModel,
            destination: destination,
            textures: textures,
            frameState: frameState,
            encoder: encoder,
            depthPixelFormat: needsDepth ? .depth32Float : .invalid
        )
        if !drewPuppetMesh {
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
        }
        frameState.registerWrite(texture: destination.texture, targetID: destination.id)
    }

    private func encodePuppetMaterialPassIfNeeded(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        puppetModel: WPEPuppetModel?,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws -> Bool {
        guard case .material = pass.pass.phase,
              case .layerComposite = pass.pass.target,
              let meshes = puppetModel?.meshes.filter({
                  !$0.vertices.isEmpty && !$0.indices.isEmpty
              }),
              !meshes.isEmpty else {
            return false
        }

        let normalizedShader = WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader)
        guard normalizedShader == "genericimage2" || normalizedShader == "genericimage4" else {
            return false
        }

        let primaryRef = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let primary = try WPEMetalShaderInputs.resolve(
            reference: primaryRef,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )

        let fragmentName = normalizedShader == "genericimage4"
            ? "wpe_genericimage4_fragment"
            : "wpe_genericimage2_fragment"
        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: "wpe_puppet_mesh_vertex",
            fragmentName: fragmentName,
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        encoder.setFragmentTexture(primary, index: 0)

        let hasMask: Bool
        if normalizedShader == "genericimage4" {
            let maskRef = pass.textureBindings[1] ?? pass.pass.textures[1]
            if let maskRef {
                let mask = try WPEMetalShaderInputs.resolve(
                    reference: maskRef,
                    textures: textures,
                    frameState: frameState,
                    currentTargetID: destination.id
                )
                encoder.setFragmentTexture(mask, index: 1)
                hasMask = true
            } else {
                encoder.setFragmentTexture(primary, index: 1)
                hasMask = false
            }
        } else {
            hasMask = false
        }

        var uniforms = genericImageUniforms(for: pass, layer: layer, hasMask: hasMask)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)

        var meshUniforms = WPEPuppetMeshUniforms(
            localSizeAndMode: SIMD4<Float>(
                Float(max(destination.texture.width, 1)),
                Float(max(destination.texture.height, 1)),
                0,
                0
            ),
            meshCenterAndPadding: SIMD4<Float>(
                Float(layer.geometry.puppetMeshCenter.x),
                Float(layer.geometry.puppetMeshCenter.y),
                0,
                0
            )
        )
        encoder.setVertexBytes(
            &meshUniforms,
            length: MemoryLayout<WPEPuppetMeshUniforms>.stride,
            index: 1
        )

        for mesh in meshes {
            let vertices = mesh.vertices.map { vertex in
                WPEMetalPuppetVertex(
                    position: SIMD4<Float>(vertex.position.x, vertex.position.y, vertex.position.z, 0),
                    uv: SIMD4<Float>(vertex.uv.x, vertex.uv.y, 0, 0)
                )
            }
            let vertexBuffer = vertices.withUnsafeBytes { rawBuffer in
                device.makeBuffer(bytes: rawBuffer.baseAddress!, length: rawBuffer.count, options: [])
            }
            guard let vertexBuffer else {
                throw WPEMetalTextureLoaderError.textureAllocationFailed
            }
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            let indices = mesh.indices
            let indexBuffer = indices.withUnsafeBytes { rawBuffer in
                device.makeBuffer(bytes: rawBuffer.baseAddress!, length: rawBuffer.count, options: [])
            }
            guard let indexBuffer else {
                throw WPEMetalTextureLoaderError.textureAllocationFailed
            }

            if mesh.parts.isEmpty {
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: indices.count,
                    indexType: .uint16,
                    indexBuffer: indexBuffer,
                    indexBufferOffset: 0
                )
            } else {
                for part in mesh.parts where part.count > 0 {
                    let start = max(part.start, 0)
                    let count = min(part.count, max(indices.count - start, 0))
                    guard count > 0 else { continue }
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: count,
                        indexType: .uint16,
                        indexBuffer: indexBuffer,
                        indexBufferOffset: start * MemoryLayout<UInt16>.stride
                    )
                }
            }
        }
        return true
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
        let initialPreviousTextureForTarget = frameState.latestTexture(for: targetID)
        let readsCurrentTarget = reference == .previous
        let destination = try targetTexture(
            for: target,
            layer: layer,
            frameState: &frameState,
            avoiding: readsCurrentTarget ? initialPreviousTextureForTarget : nil
        )

        let previousTextureForTarget: MTLTexture?
        if readsCurrentTarget {
            previousTextureForTarget = try previousTextureForRead(
                targetID: targetID,
                matching: destination.texture,
                commandBuffer: commandBuffer,
                frameState: &frameState
            )
        } else {
            previousTextureForTarget = initialPreviousTextureForTarget
        }

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
        descriptor.colorAttachments[0].clearColor = clearColor(for: destination.id)

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
        vertexName: String = "wpe_fullscreen_vertex",
        fragmentName: String,
        blendMode: String = "disabled",
        colorPixelFormat: MTLPixelFormat = WPEMetalRenderExecutor.outputPixelFormat,
        depthPixelFormat: MTLPixelFormat = .invalid
    ) throws -> MTLRenderPipelineState {
        try pipelineCache.pipelineState(
            vertexName: vertexName,
            fragmentName: fragmentName,
            blendMode: blendMode,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat
        )
    }

    func usesObjectQuadGeometry(for pass: WPEPreparedRenderPass, layer: WPERenderLayer) -> Bool {
        guard layer.geometry != .identity else { return false }
        switch pass.pass.target {
        case .scene:
            return true
        default:
            return false
        }
    }

    func objectQuadUniforms(
        for layer: WPERenderLayer,
        sceneSize: CGSize,
        sourceTexture: MTLTexture
    ) -> WPEObjectQuadUniforms {
        let geometry = layer.geometry
        let sceneWidth = Float(max(sceneSize.width, 1))
        let sceneHeight = Float(max(sceneSize.height, 1))
        let baseWidth = Float(geometry.size?.width ?? CGFloat(sourceTexture.width))
        let baseHeight = Float(geometry.size?.height ?? CGFloat(sourceTexture.height))
        let scaleX = Float(geometry.scale.x)
        let scaleY = Float(geometry.scale.y)
        let width = max(baseWidth * max(abs(scaleX), 0.0001), 0.0001)
        let height = max(baseHeight * max(abs(scaleY), 0.0001), 0.0001)
        let originX = Float(geometry.origin.x)
        let originY = Float(geometry.origin.y)
        let originXPixels = (originX >= 0 && originX <= 1) ? originX * sceneWidth : originX
        let originYPixels = (originY >= 0 && originY <= 1) ? originY * sceneHeight : originY
        let anchor = SIMD2<Float>(
            originXPixels - sceneWidth * 0.5,
            originYPixels - sceneHeight * 0.5
        )
        let center = anchor + Self.alignmentCenterOffset(
            alignment: geometry.alignment,
            width: width,
            height: height
        )
        return WPEObjectQuadUniforms(
            centerAndSize: SIMD4<Float>(center.x, center.y, width, height),
            sceneSizeAndRotation: SIMD4<Float>(
                sceneWidth,
                sceneHeight,
                Float(geometry.angles.z),
                0
            ),
            uvSignAndPadding: SIMD4<Float>(
                scaleX < 0 ? -1 : 1,
                scaleY < 0 ? -1 : 1,
                0,
                0
            )
        )
    }

    func sceneCaptureUVRect(
        for layer: WPERenderLayer,
        sceneSize: CGSize,
        sourceTexture: MTLTexture
    ) -> SIMD4<Float> {
        let quad = objectQuadUniforms(
            for: layer,
            sceneSize: sceneSize,
            sourceTexture: sourceTexture
        )
        let sceneWidth = max(quad.sceneSizeAndRotation.x, 1)
        let sceneHeight = max(quad.sceneSizeAndRotation.y, 1)
        let width = max(quad.centerAndSize.z, 0.0001)
        let height = max(quad.centerAndSize.w, 0.0001)
        let centerX = quad.centerAndSize.x + sceneWidth * 0.5
        let centerYFromBottom = quad.centerAndSize.y + sceneHeight * 0.5
        let minX = (centerX - width * 0.5) / sceneWidth
        let minY = (sceneHeight - (centerYFromBottom + height * 0.5)) / sceneHeight
        return SIMD4<Float>(
            minX,
            minY,
            width / sceneWidth,
            height / sceneHeight
        )
    }

    private static func alignmentCenterOffset(
        alignment: WPESceneAlignment,
        width: Float,
        height: Float
    ) -> SIMD2<Float> {
        switch alignment {
        case .center:
            return SIMD2<Float>(0, 0)
        case .topLeft:
            return SIMD2<Float>(width * 0.5, -height * 0.5)
        case .topRight:
            return SIMD2<Float>(-width * 0.5, -height * 0.5)
        case .bottomLeft:
            return SIMD2<Float>(width * 0.5, height * 0.5)
        case .bottomRight:
            return SIMD2<Float>(-width * 0.5, height * 0.5)
        case .top:
            return SIMD2<Float>(0, -height * 0.5)
        case .bottom:
            return SIMD2<Float>(0, height * 0.5)
        case .left:
            return SIMD2<Float>(width * 0.5, 0)
        case .right:
            return SIMD2<Float>(-width * 0.5, 0)
        }
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
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
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

    private func previousTextureForRead(
        targetID: WPEMetalTargetID,
        matching destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws -> MTLTexture {
        if let texture = frameState.latestTexture(for: targetID) {
            return texture
        }
        let texture = try makeClearedPreviousTexture(
            matching: destination,
            targetID: targetID,
            commandBuffer: commandBuffer
        )
        frameState.seedPreviousTexture(texture, targetID: targetID)
        frameState.markInitialized(texture)
        return texture
    }

    private func makeClearedPreviousTexture(
        matching texture: MTLTexture,
        targetID: WPEMetalTargetID,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let cleared = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        cleared.label = "WPE Metal bootstrap previous"
        WPEMetalTextureMetadataRegistry.shared.register(texture: cleared)

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = cleared
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = clearColor(for: targetID)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.endEncoding()
        return cleared
    }

    /// Phase 2D-E: shared dispatch path for single-input effect built-ins (opacity, scroll, pulse, iris, waterwaves).
    func dispatchSingleSampleEffect<U: BitwiseCopyable>(
        fragmentName: String,
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat,
        uniforms: U
    ) throws {
        let usesObjectQuad = usesObjectQuadGeometry(for: pass, layer: layer)
        encoder.setRenderPipelineState(try renderPipeline(
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
        var local = uniforms
        encoder.setFragmentBytes(&local, length: MemoryLayout<U>.stride, index: 0)
        if usesObjectQuad {
            var quadUniforms = objectQuadUniforms(
                for: layer,
                sceneSize: frameState.sceneSize,
                sourceTexture: texture
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
    }

    /// WPE's opacity effect optionally carries an opacity mask in texture slot 1.
    func dispatchOpacityEffect(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let usesObjectQuad = usesObjectQuadGeometry(for: pass, layer: layer)
        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: "wpe_effect_opacity_fragment",
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))

        let sourceReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let sourceTexture = try WPEMetalShaderInputs.resolve(
            reference: sourceReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        let maskReference = pass.textureBindings[1] ?? pass.pass.textures[1] ?? pass.pass.binds[1]
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

        if usesObjectQuad {
            var quadUniforms = objectQuadUniforms(
                for: layer,
                sceneSize: frameState.sceneSize,
                sourceTexture: sourceTexture
            )
            encoder.setVertexBytes(
                &quadUniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 1
            )
        }
    }

    /// Phase 2D-D: pack scene uniforms for the genericimage* built-ins.
    func genericImageUniforms(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        hasMask: Bool
    ) -> WPEGenericImageUniforms {
        WPEGenericImageUniforms(
            color: WPEMetalShaderInputs.colorVector(for: pass),
            alphaMaskUV: SIMD4<Float>(
                WPEMetalShaderInputs.floatScalar(named: ["g_Alpha", "u_Alpha", "alpha"], in: pass, default: 1)
                    * Float(layer.geometry.alpha),
                WPEMetalShaderInputs.floatScalar(named: ["g_Brightness", "u_Brightness", "brightness"], in: pass, default: 1)
                    * Float(layer.geometry.brightness),
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
        vertexName: String? = nil,
        blendMode: String,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let resolvedVertexName = vertexName ?? result.vertexFunctionName
        let key = TranslatedPipelineKey(
            libraryID: ObjectIdentifier(result.library),
            vertexName: resolvedVertexName,
            fragmentName: result.fragmentFunctionName,
            blendMode: blendMode.lowercased(),
            colorPixelFormat: colorPixelFormat.rawValue,
            depthPixelFormat: depthPixelFormat.rawValue
        )
        if let cached = translatedPipelineCache[key] {
            return cached
        }
        guard let vertex = result.library.makeFunction(name: resolvedVertexName)
            ?? device.makeDefaultLibrary()?.makeFunction(name: resolvedVertexName),
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
        layout: [WPEUniformSlot],
        texturesBySlot: [Int: MTLTexture] = [:],
        destinationTexture: MTLTexture? = nil
    ) -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: WPEShaderTranspiler.uniformSlotMaximum)
        for u in layout {
            let value = Self.textureResolutionValue(
                named: u.name,
                texturesBySlot: texturesBySlot,
                destinationTexture: destinationTexture
            ) ?? Self.translatedUniformValue(for: u, in: pass)
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

    private static func translatedUniformValue(
        for uniform: WPEUniformSlot,
        in pass: WPEPreparedRenderPass
    ) -> WPESceneShaderConstantValue? {
        let candidates = translatedUniformNameCandidates(for: uniform)
        if let value = firstValue(in: pass.uniformValues, matching: candidates) {
            return value
        }
        if let value = firstValue(in: pass.pass.constants, matching: candidates) {
            return value
        }
        return uniform.defaultValue
    }

    private static func translatedUniformNameCandidates(for uniform: WPEUniformSlot) -> [String] {
        var candidates: [String] = [uniform.name]
        if let materialName = uniform.materialName, !materialName.isEmpty {
            candidates.append(materialName)
        }
        if uniform.name.hasPrefix("u_") {
            let base = String(uniform.name.dropFirst(2))
            if !base.isEmpty {
                candidates.append(base)
                candidates.append(base.prefix(1).uppercased() + String(base.dropFirst()))
            }
        }
        var seen = Set<String>()
        return candidates.filter { candidate in
            seen.insert(candidate).inserted
        }
    }

    private static func firstValue(
        in values: [String: WPESceneShaderConstantValue],
        matching candidates: [String]
    ) -> WPESceneShaderConstantValue? {
        for candidate in candidates {
            if let value = values[candidate] {
                return value
            }
        }
        for candidate in candidates {
            let normalized = candidate.lowercased()
            if let match = values.first(where: { $0.key.lowercased() == normalized }) {
                return match.value
            }
        }
        return nil
    }

    private static func textureResolutionValue(
        named name: String,
        texturesBySlot: [Int: MTLTexture],
        destinationTexture: MTLTexture?
    ) -> WPESceneShaderConstantValue? {
        guard let slot = textureResolutionSlotIndex(for: name),
              let texture = texturesBySlot[slot] else {
            return nil
        }
        return WPEMetalTextureMetadataRegistry.shared.resolution(for: texture).shaderValue
    }

    private static func textureResolutionSlotIndex(for name: String) -> Int? {
        let prefix = "g_Texture"
        let suffix = "Resolution"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let slotText = name.dropFirst(prefix.count).dropLast(suffix.count)
        return Int(slotText)
    }

    private static func scalarValue(_ value: WPESceneShaderConstantValue?, default fallback: Float) -> Float {
        switch value {
        case .number(let n): return Float(n)
        case .vector(let v): return Float(v.first ?? Double(fallback))
        case .bool(let b):   return b ? 1 : 0
        case .animated(let v): return Float(v.scalar(at: 0) ?? Double(fallback))
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
        case .animated(let v):
            var out = (v.vector(at: 0) ?? []).map(Float.init)
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
            case .glslPreprocessFailed(let reason),
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
