#if !LITE_BUILD
import Foundation
import Metal

/// BC1/2/3/7 → RGBA8 transcode using Apple's GPU. macOS 14+ Apple
/// Silicon devices ship native BC sampler support, so the cheapest path
/// is: upload the BC blocks into an `MTLTexture`, blit-copy into an
/// `rgba8Unorm` texture, read the decoded pixels back. The same trick
/// the Pro Metal renderer uses; the WebGL path needed a CPU-side
/// `CGImage` because WebKit ships without `WEBGL_compressed_texture_s3tc`
/// by default and every BC-compressed `.tex` would otherwise fall back
/// to the magenta placeholder.
enum WPETexMetalTranscoder {

    private static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Reports whether the GPU transcoder can handle the given format.
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
        dstDescriptor.usage = [.shaderRead, .renderTarget]
        dstDescriptor.storageMode = .shared
        guard let dstTexture = device.makeTexture(descriptor: dstDescriptor),
              let queue = device.makeCommandQueue(),
              let buffer = queue.makeCommandBuffer(),
              let blit = buffer.makeBlitCommandEncoder()
        else {
            throw WPETexDecodeError.metalUnavailable(format: format)
        }
        blit.copy(
            from: srcTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: dstTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error {
            throw WPETexDecodeError.decodeFailed(mipmap: mipmap, detail: "Metal blit failed: \(error.localizedDescription)")
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
