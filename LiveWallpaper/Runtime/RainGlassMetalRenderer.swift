import CoreGraphics
import CoreImage
import Foundation
import Metal

struct RainGlassCompositeUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var brightness: Float
    var minRefraction: Float
    var refractionDelta: Float
    var alphaMultiply: Float
    var alphaSubtract: Float
    var parallaxBg: Float
    var parallaxFg: Float
    var blurRadius: Float
    var padding: Float = 0
}

/// Ring-buffered Metal texture pool shared by the rain renderer and tests.
final class RainGlassTexturePool: @unchecked Sendable {
    private struct Key: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
        let usageRawValue: UInt
    }

    private let device: MTLDevice
    private let inFlightTextureCount: Int
    private let pixelFormat: MTLPixelFormat
    private let usage: MTLTextureUsage
    private let lock = NSLock()
    private var key: Key?
    private var textures: [MTLTexture] = []
    private var cursor = 0

    init(
        device: MTLDevice,
        inFlightTextureCount: Int = 3,
        pixelFormat: MTLPixelFormat = .rgba8Unorm,
        usage: MTLTextureUsage = [.shaderWrite, .shaderRead]
    ) {
        self.device = device
        self.inFlightTextureCount = max(1, inFlightTextureCount)
        self.pixelFormat = pixelFormat
        self.usage = usage
    }

    func nextTexture(width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let requested = Key(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            usageRawValue: usage.rawValue
        )
        if key != requested || textures.count != inFlightTextureCount {
            rebuild(width: width, height: height, key: requested)
        }

        guard !textures.isEmpty else { return nil }
        let texture = textures[cursor]
        cursor = (cursor + 1) % textures.count
        return texture
    }

    private func rebuild(width: Int, height: Int, key requested: Key) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = .shared
        textures = (0..<inFlightTextureCount).compactMap { _ in device.makeTexture(descriptor: desc) }
        key = textures.isEmpty ? nil : requested
        cursor = 0
    }
}

/// Native Metal approximation of Codrops/RainEffect's water-map + refraction pass.
final class RainGlassMetalRenderer: @unchecked Sendable {
    static let inFlightTextureCount = 3

    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let waterMapPipeline: MTLComputePipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let sourcePool: RainGlassTexturePool
    private let waterMapPool: RainGlassTexturePool
    private let outputPool: RainGlassTexturePool
    private let renderLock = NSLock()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let waterMapFunction = library.makeFunction(name: "rainWaterMapCompute"),
              let waterMapPipeline = try? device.makeComputePipelineState(function: waterMapFunction),
              let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "rainGlassCompositeFragment")
        else {
            Logger.error("RainGlassMetalRenderer: failed to create Metal pipelines", category: .videoPlayer)
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm

        guard let compositePipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            Logger.error("RainGlassMetalRenderer: failed to create composite pipeline", category: .videoPlayer)
            return nil
        }

        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device)
        self.waterMapPipeline = waterMapPipeline
        self.compositePipeline = compositePipeline
        self.sourcePool = RainGlassTexturePool(
            device: device,
            inFlightTextureCount: Self.inFlightTextureCount,
            usage: [.shaderRead, .renderTarget]
        )
        self.waterMapPool = RainGlassTexturePool(
            device: device,
            inFlightTextureCount: Self.inFlightTextureCount,
            usage: [.shaderWrite, .shaderRead]
        )
        self.outputPool = RainGlassTexturePool(
            device: device,
            inFlightTextureCount: Self.inFlightTextureCount,
            usage: [.renderTarget, .shaderRead]
        )
    }

    func render(inputImage: CIImage, time: Float, width: Int, height: Int) -> CIImage? {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard width > 0, height > 0,
              let source = sourcePool.nextTexture(width: width, height: height),
              let waterMap = waterMapPool.nextTexture(width: width, height: height),
              let output = outputPool.nextTexture(width: width, height: height),
              let buffer = commandQueue.makeCommandBuffer()
        else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let cropped = inputImage
            .clampedToExtent()
            .cropped(to: bounds)

        ciContext.render(
            cropped,
            to: source,
            commandBuffer: buffer,
            bounds: bounds,
            colorSpace: colorSpace
        )
        encodeWaterMap(into: waterMap, time: time, width: width, height: height, commandBuffer: buffer)
        encodeComposite(
            source: source,
            waterMap: waterMap,
            output: output,
            time: time,
            width: width,
            height: height,
            commandBuffer: buffer
        )

        buffer.commit()
        buffer.waitUntilCompleted()

        guard var image = CIImage(mtlTexture: output, options: [.colorSpace: colorSpace]) else {
            return nil
        }
        image = image.oriented(.downMirrored)
        return image.cropped(to: bounds)
    }

    func makeWaterMapForTesting(width: Int, height: Int, time: Float) -> MTLTexture? {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard width > 0, height > 0,
              let texture = waterMapPool.nextTexture(width: width, height: height),
              let buffer = commandQueue.makeCommandBuffer()
        else { return nil }

        encodeWaterMap(into: texture, time: time, width: width, height: height, commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        return texture
    }

    private func encodeWaterMap(
        into texture: MTLTexture,
        time: Float,
        width: Int,
        height: Int,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(waterMapPipeline)
        encoder.setTexture(texture, index: 0)

        var localTime = time
        encoder.setBytes(&localTime, length: MemoryLayout<Float>.size, index: 0)
        var resolution = SIMD2<Float>(Float(width), Float(height))
        encoder.setBytes(&resolution, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }

    private func encodeComposite(
        source: MTLTexture,
        waterMap: MTLTexture,
        output: MTLTexture,
        time: Float,
        width: Int,
        height: Int,
        commandBuffer: MTLCommandBuffer
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(waterMap, index: 1)

        var uniforms = RainGlassCompositeUniforms(
            resolution: SIMD2<Float>(Float(width), Float(height)),
            time: time,
            brightness: 1.05,
            minRefraction: 18,
            refractionDelta: 94,
            alphaMultiply: 1.28,
            alphaSubtract: 0.025,
            parallaxBg: 5,
            parallaxFg: 18,
            blurRadius: 7
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RainGlassCompositeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}

class RainGlassFilter: CIFilter, @unchecked Sendable {
    @objc dynamic var inputImage: CIImage?
    @objc dynamic var inputTime: NSNumber = 0.0
    @objc dynamic var inputResolution: CIVector = CIVector(x: 1920, y: 1080)

    private static let maximumRenderDimension = 16_384

    private static let renderer: RainGlassMetalRenderer? = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.error("RainGlassFilter: Metal is unavailable", category: .videoPlayer)
            return nil
        }
        return RainGlassMetalRenderer(device: device)
    }()

    static func renderDimensions(inputResolution: CIVector, inputExtent: CGRect) -> (width: Int, height: Int)? {
        guard let width = renderDimension(preferred: inputResolution.x, fallback: inputExtent.width),
              let height = renderDimension(preferred: inputResolution.y, fallback: inputExtent.height)
        else {
            return nil
        }
        return (width, height)
    }

    private static func renderDimension(preferred: CGFloat, fallback: CGFloat) -> Int? {
        sanitizedDimension(preferred) ?? sanitizedDimension(fallback)
    }

    private static func sanitizedDimension(_ value: CGFloat) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        guard rounded >= 1, rounded <= CGFloat(maximumRenderDimension) else { return nil }
        return Int(rounded)
    }

    override var outputImage: CIImage? {
        guard let inputImage else { return nil }
        guard let renderer = Self.renderer else { return inputImage }

        guard let dimensions = Self.renderDimensions(
            inputResolution: inputResolution,
            inputExtent: inputImage.extent
        ) else {
            return inputImage
        }

        return renderer.render(
            inputImage: inputImage,
            time: inputTime.floatValue,
            width: dimensions.width,
            height: dimensions.height
        ) ?? inputImage
    }
}
