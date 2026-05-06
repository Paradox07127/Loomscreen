import CoreGraphics
import Foundation
import Metal
import MetalKit

enum WPEMetalRenderExecutorError: Error, Equatable, LocalizedError, Sendable {
    case commandQueueUnavailable
    case libraryUnavailable
    case pipelineUnavailable(String)
    case unsupportedShader(String)
    case unsupportedTarget(WPERenderTarget)
    case missingTexture(WPETextureReference)
    case noRenderablePasses
    case commandBufferFailed

    var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable:
            return "Metal command queue is unavailable."
        case .libraryUnavailable:
            return "WPE Metal built-in shader library is unavailable."
        case .pipelineUnavailable(let name):
            return "WPE Metal pipeline is unavailable for \(name)."
        case .unsupportedShader(let name):
            return "WPE Metal executor does not support shader \(name)."
        case .unsupportedTarget(let target):
            return "WPE Metal executor does not support target \(target)."
        case .missingTexture(let reference):
            return "WPE Metal executor is missing texture \(reference)."
        case .noRenderablePasses:
            return "WPE Metal pipeline has no renderable passes."
        case .commandBufferFailed:
            return "WPE Metal command buffer failed."
        }
    }
}

struct WPESolidUniforms {
    var color: SIMD4<Float>
}

struct WPECopyUniforms {
    var uvOffset: SIMD2<Float>
    var padding: SIMD2<Float> = SIMD2<Float>(0, 0)
}

/// Logical identity for a render target during one `render(...)` call.
/// `.scene` is the persistent output texture; `.named(_)` covers FBOs and
/// layer composites resolved through the pool.
private enum WPEMetalTargetID: Hashable {
    case scene
    case named(String)

    init(target: WPERenderTarget) {
        switch target {
        case .scene:
            self = .scene
        case .fbo(let name), .layerComposite(let name):
            self = .named(name)
        }
    }
}

/// Frame-local state carried through one render pass dispatch. Tracks the
/// most recent texture written per logical target so `.previous` and
/// `.fbo(name)` references resolve to live data, and so a new render pass
/// can decide between `.clear` and `.load` for its color attachment.
private struct WPEMetalFrameState {
    let output: MTLTexture
    let sceneSize: CGSize
    var latestSceneTexture: MTLTexture?
    var latestNamedTextures: [String: MTLTexture] = [:]
    var writtenTargets: Set<WPEMetalTargetID> = []
    /// Per-physical-texture init tracking. Phase 2C audit fix: ping-pong's
    /// secondary texture is allocated lazily and may contain garbage on
    /// first use. Tracking by texture identity (not target) lets us decide
    /// whether `.load` is safe or whether we need `.clear` (or a blit-copy
    /// from the previous primary) before rendering a same-target pass that
    /// blends, culls, or rejects fragments via depth.
    var initializedTextures: Set<ObjectIdentifier> = []
    var depthTextures: [WPEMetalDepthTextureKey: MTLTexture] = [:]

    func latestTexture(for targetID: WPEMetalTargetID) -> MTLTexture? {
        switch targetID {
        case .scene:
            return latestSceneTexture
        case .named(let name):
            return latestNamedTextures[name]
        }
    }

    mutating func registerWrite(texture: MTLTexture, targetID: WPEMetalTargetID) {
        writtenTargets.insert(targetID)
        initializedTextures.insert(ObjectIdentifier(texture))
        switch targetID {
        case .scene:
            latestSceneTexture = texture
        case .named(let name):
            latestNamedTextures[name] = texture
        }
    }

    mutating func markInitialized(_ texture: MTLTexture) {
        initializedTextures.insert(ObjectIdentifier(texture))
    }

    func hasInitialized(_ texture: MTLTexture) -> Bool {
        initializedTextures.contains(ObjectIdentifier(texture))
    }

    func hasWritten(_ targetID: WPEMetalTargetID) -> Bool {
        writtenTargets.contains(targetID)
    }
}

private struct WPEMetalPipelineKey: Hashable {
    let fragmentName: String
    let blendMode: String
    let colorPixelFormat: MTLPixelFormat
    /// Phase 2C audit fix: every PSO must declare the SAME depth attachment
    /// format as the render pass that drives it. We default to `.invalid`
    /// for non-depth passes so Metal's API validation does not fail when a
    /// fullscreen copy without depth meets a pipeline that thought it had
    /// `.depth32Float` attached.
    let depthPixelFormat: MTLPixelFormat
}

private struct WPEMetalDepthKey: Hashable {
    let depthTest: String
    let depthWrite: String
}

/// Per-frame depth-texture identity. Keys by (target, exact size) so a
/// scaled FBO's depth attachment matches its color attachment dimensions.
private struct WPEMetalDepthTextureKey: Hashable {
    let targetID: WPEMetalTargetID
    let width: Int
    let height: Int
}

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

    var transientTargetTextureCountForTesting: Int {
        targetPool.allocatedTextureCount
    }

    var pipelineStateCountForTesting: Int {
        pipelines.count
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

        let resolvedTextures = WPEMetalResolvedShaderInputs(executor: self)
        try resolvedTextures.dispatch(
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

    fileprivate func copyUniforms(for pass: WPEPreparedRenderPass, layer: WPERenderLayer) -> WPECopyUniforms {
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

    fileprivate func renderPipeline(
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
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        applyBlendMode(normalizedBlend, to: descriptor.colorAttachments[0]!)

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

    fileprivate func colorVector(for pass: WPEPreparedRenderPass) -> SIMD4<Float> {
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

    fileprivate func resolve(
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
    /// `compose`, and `genericimage*` aliases (with or without the
    /// `materials/util/` prefix and `.json` suffix). Custom shaders still
    /// throw `unsupportedShader` until Phase 2D ships GLSL translation.
    fileprivate func normalizedBuiltinShaderName(_ shaderName: String) -> String {
        let lower = shaderName.lowercased()
        let withoutJSON = lower.hasSuffix(".json") ? String(lower.dropLast(5)) : lower
        switch withoutJSON {
        case "solidcolor":
            return "solidcolor"
        case "solidlayer", "materials/util/solidlayer", "models/util/solidlayer":
            return "solidlayer"
        case "copy", "commands/copy", "materials/util/copy":
            return "copy"
        case "compose", "materials/util/compose":
            return "compose"
        default:
            if withoutJSON.hasPrefix("genericimage") {
                return "copy"
            }
            return withoutJSON
        }
    }
}

/// Dispatches a prepared pass onto the right Metal pipeline state and
/// fragment uniforms. Extracted so the dispatch logic can stay readable
/// while sharing access to the executor's pipeline cache, color uniforms,
/// and texture resolution helpers.
private struct WPEMetalResolvedShaderInputs {
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
        switch executor.normalizedBuiltinShaderName(pass.pass.shader) {
        case "solidcolor":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_solidcolor_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            var uniforms = WPESolidUniforms(color: executor.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)

        case "solidlayer":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_solidlayer_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            var uniforms = WPESolidUniforms(color: executor.colorVector(for: pass))
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
            let texture = try executor.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            if fragmentName == "wpe_copy_fragment" {
                var uniforms = executor.copyUniforms(for: pass, layer: layer)
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
            let firstTexture = try executor.resolve(
                reference: firstReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            let secondTexture = try executor.resolve(
                reference: secondReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(firstTexture, index: 0)
            encoder.setFragmentTexture(secondTexture, index: 1)
            var uniforms = WPESolidUniforms(color: executor.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)

        default:
            throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
