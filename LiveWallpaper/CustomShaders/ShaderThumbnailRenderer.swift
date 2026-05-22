#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import Metal
import MetalKit

/// Offscreen single-frame renderer for the shader picker grid. Renders the
/// fragment shader once into a small `MTLTexture`, reads back to an
/// `NSImage`, and caches the result so the picker grid never repaints from
/// the GPU after the first appearance.
///
/// Two key choices:
/// 1. Time is fixed at `1.5s` rather than 0 — most procedural shaders look
///    flat / monochromatic at t=0 (Aurora bands haven't moved yet, Plasma
///    metaballs are stacked at center, etc.); 1.5 seconds is enough warmup
///    for each preset to look visually distinct without being far enough
///    out that they all blur into mid-cycle noise.
/// 2. No MSAA on thumbnails — the destination texture is BGRA8Unorm with
///    `rasterSampleCount = 1`. Pipeline reuse with the live renderer would
///    require samplers that match its 4× MSAA, but the thumbnail is shown
///    at 88pt × 60pt where MSAA buys nothing.
@MainActor
final class ShaderThumbnailRenderer {
    static let shared = ShaderThumbnailRenderer()

    /// Logical card size used by the picker grid. Backing-store size is
    /// `cardSize × NSScreen.main.backingScaleFactor` so the bitmap reads
    /// crisp on retina.
    static let cardSize = CGSize(width: 88, height: 60)

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let defaultLibrary: MTLLibrary?

    /// Result cache: one `NSImage` per (source, backing-store size) pair.
    /// Sized in pixels (post-DPR) so the same source rendered at 2× and 3×
    /// don't fight for a single slot.
    private let imageCache = NSCache<NSString, NSImage>()

    /// Compiled pipelines, keyed by source. Custom shaders compile lazily
    /// and stay cached until `invalidate(_:)` evicts them (e.g. on delete).
    private var pipelineCache: [String: MTLRenderPipelineState] = [:]

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        self.defaultLibrary = device?.makeDefaultLibrary()
        imageCache.countLimit = 64
    }

    // MARK: - Public API

    /// Returns a cached thumbnail or renders one synchronously. Returns
    /// `nil` only when Metal is unsupported or the custom shader's source
    /// fails to compile (caller falls back to an SF Symbol).
    func thumbnail(for source: ShaderSource, pointSize: CGSize, scale: CGFloat) -> NSImage? {
        let pixelWidth  = max(1, Int((pointSize.width  * scale).rounded()))
        let pixelHeight = max(1, Int((pointSize.height * scale).rounded()))
        let cacheKey = key(for: source, pixelWidth: pixelWidth, pixelHeight: pixelHeight) as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        guard let image = render(source: source, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            return nil
        }
        image.size = pointSize
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// Drop every cached entry (image + pipeline) for the given source.
    /// Called when a custom shader is re-imported or deleted so the next
    /// `thumbnail(for:)` returns a fresh render.
    func invalidate(_ source: ShaderSource) {
        let pipelineKey = pipelineCacheKey(for: source)
        pipelineCache.removeValue(forKey: pipelineKey)

        // NSCache lacks key enumeration; remove all and let the picker
        // re-warm. For 5 builtins + N customs this is cheap enough.
        imageCache.removeAllObjects()
    }

    // MARK: - Render

    private func render(source: ShaderSource, pixelWidth: Int, pixelHeight: Int) -> NSImage? {
        guard let device, let commandQueue else { return nil }

        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try resolvePipeline(for: source, device: device)
        } catch {
            Logger.warning("Shader thumbnail compile failed: \(error.localizedDescription)", category: .videoPlayer)
            return nil
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelWidth,
            height: pixelHeight,
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
            resolution: SIMD2<Float>(Float(pixelWidth), Float(pixelHeight)),
            shaderType: source.builtinPreset.map(Self.shaderTypeIndex(for:)) ?? 0
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        buffer.commit()
        buffer.waitUntilCompleted()

        return makeImage(from: texture, width: pixelWidth, height: pixelHeight)
    }

    private func resolvePipeline(for source: ShaderSource, device: MTLDevice) throws -> MTLRenderPipelineState {
        let key = pipelineCacheKey(for: source)
        if let cached = pipelineCache[key] { return cached }

        let library: MTLLibrary
        switch source {
        case .builtin:
            guard let defaultLibrary else {
                throw CustomShaderCompileError.metalUnsupported
            }
            library = defaultLibrary
        case .custom(let id):
            guard let shader = CustomShaderStore.shared.shader(for: id) else {
                throw CustomShaderCompileError.compileFailed(message: "Shader not found")
            }
            library = try MetalWallpaperView.compileCustomShader(source: shader.source, on: device)
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
        pipelineCache[key] = pipeline
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

    // MARK: - Keys

    private func key(for source: ShaderSource, pixelWidth: Int, pixelHeight: Int) -> String {
        "\(pipelineCacheKey(for: source))_\(pixelWidth)x\(pixelHeight)"
    }

    private func pipelineCacheKey(for source: ShaderSource) -> String {
        switch source {
        case .builtin(let preset): return "builtin:\(preset.rawValue)"
        case .custom(let id):      return "custom:\(id.uuidString)"
        }
    }

    private static func shaderTypeIndex(for preset: MetalShaderPreset) -> Int32 {
        switch preset {
        case .waves:    return 0
        case .plasma:   return 1
        case .gradient: return 2
        case .noise:    return 3
        case .aurora:   return 4
        }
    }
}
#endif
