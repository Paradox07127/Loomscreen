import CoreGraphics
import Foundation
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
    private let library: MTLLibrary
    private let targetPool: WPEMetalRenderTargetPool
    private var pipelines: [WPEMetalPipelineKey: MTLRenderPipelineState] = [:]
    private var depthStates: [WPEMetalDepthKey: MTLDepthStencilState] = [:]

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else {
            throw WPEMetalRenderExecutorError.commandQueueUnavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw WPEMetalRenderExecutorError.libraryUnavailable
        }
        self.device = device
        commandQueue = queue
        self.library = library
        self.targetPool = WPEMetalRenderTargetPool(device: device)
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

        // Phase 2C audit fix: when ping-pong allocates a fresh secondary
        // texture for `.previous`, copy the prior contents in so blend /
        // cull / depth-rejected fragments do not see uninitialised memory.
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

        let needsDepth = needsDepthAttachment(pass: pass)

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        descriptor.colorAttachments[0].loadAction = frameState.hasInitialized(destination.texture) ? .load : .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if needsDepth {
            let depth = try depthTexture(for: destination, frameState: &frameState)
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
        encoder.setCullMode(cullMode(for: pass.pass.cullMode))
        encoder.setDepthStencilState(depthStencilState(
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

    /// Phase 2C audit fix: blit-copies a prior physical texture into the
    /// pool's secondary slot so ping-pong renders that blend or depth-test
    /// have a defined source to load.
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
            try resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            ),
            index: 0
        )
        var uniforms = WPECopyUniforms(
            uvOffset: Self.parallaxUVOffset(
                pointerPosition: runtimeUniforms.pointerPosition,
                parallaxDepth: layer.parallaxDepth
            )
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPECopyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        frameState.registerWrite(texture: destination.texture, targetID: destination.id)
    }

    /// Conservative WPE mouse-parallax model. The shader receives a UV
    /// offset bounded to ±0.05 so a layer with depth 0.1 and the cursor at
    /// the screen edge shifts samples by 5% — enough to feel parallax
    /// without exposing texture borders. Phase 2D's GLSL translator will
    /// replace this with the full WPE camera-parallax math.
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

    func copyUniforms(for pass: WPEPreparedRenderPass, layer: WPERenderLayer) -> WPECopyUniforms {
        let vector = pass.uniformValues["g_PointerPosition"]?.vectorValue ?? [0.5, 0.5]
        let pointer = SIMD2<Double>(
            vector[safe: 0] ?? 0.5,
            vector[safe: 1] ?? 0.5
        )
        return WPECopyUniforms(
            uvOffset: Self.parallaxUVOffset(
                pointerPosition: pointer,
                parallaxDepth: layer.parallaxDepth
            )
        )
    }

    func renderPipeline(
        fragmentName: String,
        blendMode: String = "disabled",
        colorPixelFormat: MTLPixelFormat = WPEMetalRenderExecutor.outputPixelFormat,
        depthPixelFormat: MTLPixelFormat = .invalid
    ) throws -> MTLRenderPipelineState {
        let normalizedBlend = blendMode.lowercased()
        let key = WPEMetalPipelineKey(
            fragmentName: fragmentName,
            blendMode: normalizedBlend,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat
        )
        if let cached = pipelines[key] {
            return cached
        }

        guard let vertex = library.makeFunction(name: "wpe_fullscreen_vertex"),
              let fragment = library.makeFunction(name: fragmentName) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(fragmentName)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let colorAttachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(fragmentName)
        }
        colorAttachment.pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        applyBlendMode(normalizedBlend, to: colorAttachment)

        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = state
        return state
    }

    private func applyBlendMode(
        _ mode: String,
        to attachment: MTLRenderPipelineColorAttachmentDescriptor
    ) {
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
            // WPE multiply preserves the destination alpha (OpenGL convention).
            // RGB = src.rgb * dst.rgb; alpha = dst.alpha.
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .destinationColor
            attachment.destinationRGBBlendFactor = .zero
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one

        case "translucent":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        case "normalmapped", "normal":
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

    private func cullMode(for raw: String) -> MTLCullMode {
        switch raw.lowercased() {
        case "back":
            return .back
        case "front":
            return .front
        default:
            return .none
        }
    }

    private func needsDepthAttachment(pass: WPEPreparedRenderPass) -> Bool {
        pass.pass.depthWrite.lowercased() == "enabled"
            || pass.pass.depthWrite.lowercased() == "true"
            || pass.pass.depthTest.lowercased() != "disabled"
    }

    private func makeDepthTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE Metal executor depth"
        return texture
    }

    /// Phase 2C audit fix: depth textures key on (target, exact destination
    /// dimensions) so a scaled FBO's depth attachment matches its color
    /// attachment dimensions instead of being stuck at scene size.
    private func depthTexture(
        for destination: (id: WPEMetalTargetID, texture: MTLTexture),
        frameState: inout WPEMetalFrameState
    ) throws -> MTLTexture {
        let key = WPEMetalDepthTextureKey(
            targetID: destination.id,
            width: destination.texture.width,
            height: destination.texture.height
        )
        if let existing = frameState.depthTextures[key] {
            return existing
        }
        let texture = try makeDepthTexture(width: key.width, height: key.height)
        frameState.depthTextures[key] = texture
        return texture
    }

    private func depthStencilState(depthTest: String, depthWrite: String) -> MTLDepthStencilState {
        let key = WPEMetalDepthKey(
            depthTest: depthTest.lowercased(),
            depthWrite: depthWrite.lowercased()
        )
        if let cached = depthStates[key] {
            return cached
        }

        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = depthCompareFunction(for: key.depthTest)
        descriptor.isDepthWriteEnabled = key.depthWrite == "enabled" || key.depthWrite == "true"

        let state = device.makeDepthStencilState(descriptor: descriptor)!
        depthStates[key] = state
        return state
    }

    private func depthCompareFunction(for raw: String) -> MTLCompareFunction {
        switch raw.lowercased() {
        case "always":
            return .always
        case "never":
            return .never
        case "less":
            return .less
        case "lequal", "lessequal", "less_equal":
            return .lessEqual
        case "greater":
            return .greater
        case "gequal", "greaterequal", "greater_equal":
            return .greaterEqual
        case "equal":
            return .equal
        case "notequal", "not_equal":
            return .notEqual
        default:
            return .always
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

    func colorVector(for pass: WPEPreparedRenderPass) -> SIMD4<Float> {
        // WPE scene JSON authors `g_Color` in sRGB perceptual space ("0.5 0.5
        // 0.5" → mid-gray on screen). The render target is sRGB-tagged, so
        // the hardware applies linear→sRGB encode on store; we therefore
        // must feed the shader linear-space RGB. Alpha stays unchanged —
        // Metal does not gamma-encode the alpha channel on sRGB targets.
        let vector = pass.uniformValues["g_Color"]?.vectorValue
            ?? pass.pass.constants["g_Color"]?.vectorValue
            ?? [1, 1, 1, 1]
        return SIMD4<Float>(
            Self.sRGBToLinear(Float(vector[safe: 0] ?? 1)),
            Self.sRGBToLinear(Float(vector[safe: 1] ?? 1)),
            Self.sRGBToLinear(Float(vector[safe: 2] ?? 1)),
            Float(vector[safe: 3] ?? 1)
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

    func resolve(
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
            guard let texture = frameState.latestNamedTextures[name] else {
                throw WPEMetalRenderExecutorError.missingTexture(reference)
            }
            return texture

        case .previous:
            guard let texture = frameState.latestTexture(for: currentTargetID) else {
                throw WPEMetalRenderExecutorError.missingTexture(reference)
            }
            return texture
        }
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

    /// Maps the WPE shader name onto one of the executor's built-in fragment
    /// functions. Phase 2C recognises `solidcolor`, `solidlayer`, `copy`,
    /// `compose`, and `genericimage*`. Phase 2D-C extends the table with the
    /// pre-compiled MSL effect set: `colorbalance`, `blur`, `vignette`,
    /// `water` (alias `distort`), `shake`. Custom shaders still throw
    /// `unsupportedShader` until the full GLSL translator (Phase 2D-A/B)
    /// lands.
    func normalizedBuiltinShaderName(_ shaderName: String) -> String {
        WPEBuiltinShaderName.normalized(shaderName, genericImageAsCopy: true)
    }

    /// Phase 2D-C: scalar-uniform lookup that walks `pass.uniformValues`
    /// first (runtime-merged values from Phase 2B) then `pass.pass.constants`
    /// (authored material defaults). Multiple aliases supported because WPE
    /// shader uniforms ship under several legacy names (`u_X`, `X`,
    /// `g_XOffset`, etc.).
    func floatScalar(
        named name: String,
        in pass: WPEPreparedRenderPass,
        default defaultValue: Float
    ) -> Float {
        Self.scalarFloat(pass.uniformValues[name])
            ?? Self.scalarFloat(pass.pass.constants[name])
            ?? defaultValue
    }

    func floatScalar(
        named names: [String],
        in pass: WPEPreparedRenderPass,
        default defaultValue: Float
    ) -> Float {
        for name in names {
            if let value = Self.scalarFloat(pass.uniformValues[name]) {
                return value
            }
        }
        for name in names {
            if let value = Self.scalarFloat(pass.pass.constants[name]) {
                return value
            }
        }
        return defaultValue
    }

    private static func scalarFloat(_ value: WPESceneShaderConstantValue?) -> Float? {
        switch value {
        case .number(let number):
            return Float(number)
        case .vector(let vector):
            return vector.first.map(Float.init)
        case .bool(let bool):
            return bool ? 1 : 0
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
