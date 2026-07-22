#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import Metal
import MetalKit

/// Offscreen single-frame renderer for the shader picker grid.
@MainActor
final class ShaderThumbnailRenderer {
    static let shared = ShaderThumbnailRenderer()

    static let cardSize = CGSize(width: 88, height: 60)

    /// One `NSImage` per (source, backing-store size). NSCache is thread-safe
    /// so the render helper can write from any thread.
    private let imageCache = NSCache<NSString, NSImage>()

    @ObservationIgnored
    private let helper = ThumbnailRenderHelper()

    init() {
        imageCache.countLimit = 64
    }

    // MARK: - Public API

    /// Cheap; safe to call from SwiftUI `body`.
    func cachedThumbnail(for source: ShaderSource, pointSize: CGSize, scale: CGFloat) -> NSImage? {
        let (pixelWidth, pixelHeight) = pixelDimensions(pointSize: pointSize, scale: scale)
        return imageCache.object(forKey: cacheKey(for: source, pixelWidth: pixelWidth, pixelHeight: pixelHeight) as NSString)
    }

    /// Renders off-main; returns `nil` on compile / Metal failure.
    func renderThumbnail(for source: ShaderSource, pointSize: CGSize, scale: CGFloat) async -> NSImage? {
        if let cached = cachedThumbnail(for: source, pointSize: pointSize, scale: scale) {
            return cached
        }

        let (pixelWidth, pixelHeight) = pixelDimensions(pointSize: pointSize, scale: scale)
        // Resolve the custom shader's source on MainActor before detaching; the helper runs off MainActor and cannot touch the @Observable store directly.
        let customSource = source.customID.flatMap { CustomShaderStore.shared.shader(for: $0)?.source }

        let request = ThumbnailRequest(
            source: source,
            customSource: customSource,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )

        let helper = self.helper
        let image = await Task.detached(priority: .userInitiated) {
            helper.render(request)
        }.value

        guard let image else { return nil }
        image.size = pointSize
        imageCache.setObject(
            image,
            forKey: cacheKey(for: source, pixelWidth: pixelWidth, pixelHeight: pixelHeight) as NSString
        )
        return image
    }

    /// Called when a custom shader is re-imported or deleted so the next
    /// request re-renders.
    func invalidate(_ source: ShaderSource) {
        helper.invalidate(source)
        imageCache.removeAllObjects()
    }

    // MARK: - Helpers

    private func pixelDimensions(pointSize: CGSize, scale: CGFloat) -> (Int, Int) {
        (
            max(1, Int((pointSize.width  * scale).rounded())),
            max(1, Int((pointSize.height * scale).rounded()))
        )
    }

    private func cacheKey(for source: ShaderSource, pixelWidth: Int, pixelHeight: Int) -> String {
        "\(ThumbnailRenderHelper.pipelineKey(for: source))_\(pixelWidth)x\(pixelHeight)"
    }
}

// MARK: - ThumbnailRenderHelper (nonisolated)

/// One Metal device + pipeline cache shared across thumbnail renders.
private final class ThumbnailRenderHelper: @unchecked Sendable {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let defaultLibrary: MTLLibrary?

    private let lock = NSLock()
    private var pipelineCache: [String: MTLRenderPipelineState] = [:]
    /// LRU ordering — oldest first. Eviction trims to `pipelineCacheLimit`.
    private var pipelineOrder: [String] = []
    private let pipelineCacheLimit = 32

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        self.defaultLibrary = device?.makeDefaultLibrary()
    }

    static func pipelineKey(for source: ShaderSource) -> String {
        switch source {
        case .builtin(let preset): return "builtin:\(preset.rawValue)"
        case .custom(let id):      return "custom:\(id.uuidString)"
        }
    }

    func invalidate(_ source: ShaderSource) {
        let key = Self.pipelineKey(for: source)
        lock.lock()
        defer { lock.unlock() }
        pipelineCache.removeValue(forKey: key)
        pipelineOrder.removeAll { $0 == key }
    }

    func render(_ request: ThumbnailRequest) -> NSImage? {
        guard let device, let commandQueue else { return nil }

        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try resolvePipeline(for: request, device: device)
        } catch {
            return nil
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: request.pixelWidth,
            height: request.pixelHeight,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPass.colorAttachments[0].storeAction = .store

        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return nil
        }

        var uniforms = ShaderUniforms(
            time: 1.5,
            resolution: SIMD2<Float>(Float(request.pixelWidth), Float(request.pixelHeight)),
            shaderType: request.source.builtinPreset?.shaderTypeIndex ?? 0
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        buffer.commit()
        buffer.waitUntilCompleted()

        return makeImage(from: texture, width: request.pixelWidth, height: request.pixelHeight)
    }

    private func resolvePipeline(for request: ThumbnailRequest, device: MTLDevice) throws -> MTLRenderPipelineState {
        let key = Self.pipelineKey(for: request.source)

        lock.lock()
        if let cached = pipelineCache[key] {
            pipelineOrder.removeAll { $0 == key }
            pipelineOrder.append(key)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let library: MTLLibrary
        switch request.source {
        case .builtin:
            guard let defaultLibrary else {
                throw CustomShaderCompileError.metalUnsupported
            }
            library = defaultLibrary
        case .custom:
            guard let customSource = request.customSource else {
                throw CustomShaderCompileError.compileFailed(message: "Shader not found")
            }
            library = try MetalWallpaperView.compileCustomShader(source: customSource, on: device)
        }

        guard let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
            throw CustomShaderCompileError.compileFailed(message: "Shader functions not found")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.rasterSampleCount = 1

        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        lock.lock()
        defer { lock.unlock() }
        pipelineCache[key] = pipeline
        pipelineOrder.append(key)
        if pipelineOrder.count > pipelineCacheLimit {
            let evict = pipelineOrder.removeFirst()
            pipelineCache.removeValue(forKey: evict)
        }
        return pipeline
    }

    private func makeImage(from texture: MTLTexture, width: Int, height: Int) -> NSImage? {
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(
            &bytes,
            bytesPerRow: rowBytes,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = [
            .byteOrder32Little,
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        ]

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}

/// Immutable render request — `Sendable` so it crosses into `Task.detached`
/// without compiler warnings under Swift 6 strict concurrency.
private struct ThumbnailRequest: Sendable {
    let source: ShaderSource
    let customSource: String?
    let pixelWidth: Int
    let pixelHeight: Int
}
#endif
