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

final class WPEMetalRenderExecutor {
    /// Phase 2A H3: every offscreen target and the on-screen swapchain share a
    /// single sRGB pixel format so render pipelines built for the offscreen
    /// pass can be reused by `present()` without re-creation, and so the
    /// rendered gamma matches the SpriteKit/CGImage fallback on the same
    /// scene fixture.
    static let outputPixelFormat: MTLPixelFormat = .rgba8Unorm_srgb

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [String: MTLRenderPipelineState] = [:]

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
    }

    func render(
        pipeline: WPEPreparedRenderPipeline,
        size: CGSize,
        textures: [String: MTLTexture]
    ) throws -> MTLTexture {
        let output = try makeOutputTexture(size: size)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        var shouldClear = true
        var didEncode = false
        for layer in pipeline.layers {
            if layer.passes.isEmpty {
                try encodeCopy(
                    reference: .image(layer.graphLayer.imagePath),
                    output: output,
                    textures: textures,
                    commandBuffer: commandBuffer,
                    shouldClear: shouldClear
                )
                shouldClear = false
                didEncode = true
                continue
            }
            for pass in layer.passes {
                try encode(
                    pass: pass,
                    output: output,
                    textures: textures,
                    commandBuffer: commandBuffer,
                    shouldClear: shouldClear
                )
                shouldClear = false
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
        encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_copy_fragment"))
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    private func encode(
        pass: WPEPreparedRenderPass,
        output: MTLTexture,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer,
        shouldClear: Bool
    ) throws {
        guard pass.pass.target == .scene else {
            throw WPEMetalRenderExecutorError.unsupportedTarget(pass.pass.target)
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = shouldClear ? .clear : .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        defer { encoder.endEncoding() }

        if pass.pass.shader == "solidcolor" {
            encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_solidcolor_fragment"))
            var uniforms = WPESolidUniforms(color: colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
        } else if pass.pass.shader == "commands/copy" || pass.pass.shader.hasPrefix("genericimage") {
            encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_copy_fragment"))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try resolve(reference: reference, textures: textures)
            encoder.setFragmentTexture(texture, index: 0)
        } else {
            throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
        }

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func encodeCopy(
        reference: WPETextureReference,
        output: MTLTexture,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer,
        shouldClear: Bool
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = shouldClear ? .clear : .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        defer { encoder.endEncoding() }

        encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_copy_fragment"))
        encoder.setFragmentTexture(try resolve(reference: reference, textures: textures), index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func renderPipeline(fragmentName: String) throws -> MTLRenderPipelineState {
        if let cached = pipelines[fragmentName] {
            return cached
        }
        guard let vertex = library.makeFunction(name: "wpe_fullscreen_vertex"),
              let fragment = library.makeFunction(name: fragmentName) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(fragmentName)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.outputPixelFormat

        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[fragmentName] = state
        return state
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

    private func colorVector(for pass: WPEPreparedRenderPass) -> SIMD4<Float> {
        // WPE scene JSON authors `g_Color` in sRGB perceptual space ("0.5 0.5
        // 0.5" → mid-gray on screen). The render target is sRGB-tagged, so the
        // hardware applies linear→sRGB encode on store; we therefore must feed
        // the shader linear-space RGB. Alpha stays unchanged — Metal does not
        // gamma-encode the alpha channel on sRGB targets.
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

    private func resolve(reference: WPETextureReference, textures: [String: MTLTexture]) throws -> MTLTexture {
        switch reference {
        case .image(let path), .asset(let path), .fbo(let path):
            guard let texture = textures[path] else {
                throw WPEMetalRenderExecutorError.missingTexture(reference)
            }
            return texture
        case .previous:
            throw WPEMetalRenderExecutorError.missingTexture(reference)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
