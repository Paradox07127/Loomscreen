#if !LITE_BUILD
import Foundation
import Metal
import LiveWallpaperProWPE

/// BC1/2/3/7 → RGBA8 transcode using Apple's GPU (sample BC into an
/// `rgba8Unorm` render target, read back).
///
/// Not `MTLBlitCommandEncoder.copy`: blit is a bit-for-bit copy, so it
/// reinterprets BC block bytes as RGBA pixels (green-tinted noise) instead
/// of decompressing. Decompression must go through a sampling shader.
///
/// Loader fallback when native BC upload is unavailable, avoiding the
/// magenta placeholder path.
enum WPETexMetalTranscoder {

    private static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// `nonisolated(unsafe)`: Metal pipeline objects are thread-safe and the
    /// only writers are the lazy first-init guarded by `pipelineLock`.
    nonisolated(unsafe) private static var pipelineState: MTLRenderPipelineState?
    nonisolated(unsafe) private static var commandQueue: MTLCommandQueue?
    nonisolated(unsafe) private static var samplerState: MTLSamplerState?
    private static let pipelineLock = NSLock()

    static func isAvailable(for format: WPETexFormat) -> Bool {
        guard let device, device.supportsBCTextureCompression else { return false }
        return mtlPixelFormat(for: format) != nil
    }

    static func transcode(
        _ bytes: Data,
        format: WPETexFormat,
        width: Int,
        height: Int,
        mipmap: Int
    ) throws -> DecodedRGBAImage {
        guard let device else {
            throw WPETexDecodeError.metalUnavailable(format: format)
        }
        guard device.supportsBCTextureCompression else {
            throw WPETexDecodeError.metalUnavailable(format: format)
        }
        guard let pixelFormat = mtlPixelFormat(for: format) else {
            throw WPETexDecodeError.unsupportedFormat(code: format.rawValue)
        }

        let blockBytes = blockByteSize(for: format)
        let blocksWide = max(1, (width + 3) / 4)
        let bytesPerRow = blocksWide * blockBytes

        let srcDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        srcDescriptor.usage = [.shaderRead]
        srcDescriptor.storageMode = .shared
        guard let srcTexture = device.makeTexture(descriptor: srcDescriptor) else {
            throw WPETexDecodeError.metalUnavailable(format: format)
        }
        bytes.withUnsafeBytes { rawBufferPointer in
            guard let base = rawBufferPointer.baseAddress else { return }
            srcTexture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }

        let dstDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        dstDescriptor.usage = [.renderTarget, .shaderRead]
        dstDescriptor.storageMode = .shared
        guard let dstTexture = device.makeTexture(descriptor: dstDescriptor) else {
            throw WPETexDecodeError.metalUnavailable(format: format)
        }

        let resources = try ensureResources(device: device, mipmap: mipmap)

        guard let buffer = resources.queue.makeCommandBuffer() else {
            throw WPETexDecodeError.decodeFailed(mipmap: mipmap, detail: "Metal command buffer unavailable")
        }

        let renderDescriptor = MTLRenderPassDescriptor()
        renderDescriptor.colorAttachments[0].texture = dstTexture
        renderDescriptor.colorAttachments[0].loadAction = .dontCare
        renderDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: renderDescriptor) else {
            throw WPETexDecodeError.decodeFailed(mipmap: mipmap, detail: "Metal render command encoder unavailable")
        }
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setFragmentTexture(srcTexture, index: 0)
        encoder.setFragmentSamplerState(resources.sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error {
            throw WPETexDecodeError.decodeFailed(mipmap: mipmap, detail: "Metal BC decode failed: \(error.localizedDescription)")
        }

        let pixelByteCount = width * height * 4
        var pixels = Data(count: pixelByteCount)
        pixels.withUnsafeMutableBytes { rawBufferPointer in
            guard let base = rawBufferPointer.baseAddress else { return }
            dstTexture.getBytes(
                base,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return DecodedRGBAImage(width: width, height: height, pixels: pixels)
    }

    private struct DecodeResources {
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let sampler: MTLSamplerState
    }

    private static func ensureResources(device: MTLDevice, mipmap: Int) throws -> DecodeResources {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }

        if let queue = commandQueue,
           let pipeline = pipelineState,
           let sampler = samplerState {
            return DecodeResources(queue: queue, pipeline: pipeline, sampler: sampler)
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw WPETexDecodeError.decodeFailed(
                mipmap: mipmap,
                detail: "Metal BC decoder shader compile failed: \(error.localizedDescription)"
            )
        }
        guard let vertex = library.makeFunction(name: "wpe_tex_decode_vertex"),
              let fragment = library.makeFunction(name: "wpe_tex_decode_fragment") else {
            throw WPETexDecodeError.decodeFailed(
                mipmap: mipmap,
                detail: "Metal BC decoder shader entry points missing"
            )
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm

        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw WPETexDecodeError.decodeFailed(
                mipmap: mipmap,
                detail: "Metal BC decoder pipeline build failed: \(error.localizedDescription)"
            )
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw WPETexDecodeError.decodeFailed(
                mipmap: mipmap,
                detail: "Metal BC decoder sampler unavailable"
            )
        }

        guard let queue = device.makeCommandQueue() else {
            throw WPETexDecodeError.metalUnavailable(format: .rgba8888)
        }

        pipelineState = pipeline
        samplerState = sampler
        commandQueue = queue
        return DecodeResources(queue: queue, pipeline: pipeline, sampler: sampler)
    }

    /// UV flips Y so the readback matches BC texel order (BC row 0 = top).
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct WPETexDecodeVertex {
        float4 position [[position]];
        float2 uv;
    };

    vertex WPETexDecodeVertex wpe_tex_decode_vertex(uint vertexID [[vertex_id]]) {
        float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        float2 uvs[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };
        WPETexDecodeVertex out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.uv = uvs[vertexID];
        return out;
    }

    fragment float4 wpe_tex_decode_fragment(
        WPETexDecodeVertex in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        return source.sample(samp, in.uv);
    }
    """

    private static func mtlPixelFormat(for format: WPETexFormat) -> MTLPixelFormat? {
        switch format {
        case .dxt1: return .bc1_rgba
        case .dxt3: return .bc2_rgba
        case .dxt5: return .bc3_rgba
        case .bc7:  return .bc7_rgbaUnorm
        default:    return nil
        }
    }

    private static func blockByteSize(for format: WPETexFormat) -> Int {
        switch format {
        case .dxt1: return 8
        case .dxt3, .dxt5, .bc7: return 16
        default: return 16
        }
    }
}
#endif
