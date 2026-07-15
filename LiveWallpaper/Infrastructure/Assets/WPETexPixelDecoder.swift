#if !LITE_BUILD
import Foundation

/// CPU pixel-decode paths for the uncompressed `.tex` formats; BC formats
/// live in `WPETexMetalTranscoder`. Output is `kCGImageAlphaLast` byte order
/// so the caller can hand it straight to `CGImage` / `SKTexture(cgImage:)`.
enum WPETexPixelDecoder {

    static func decodeRGBA8888(
        _ bytes: Data,
        width: Int,
        height: Int,
        mipmap: Int
    ) throws -> DecodedRGBAImage {
        let expected = width * height * 4
        guard bytes.count == expected else {
            throw WPETexDecodeError.decodeFailed(
                mipmap: mipmap,
                detail: "RGBA8888 byte count mismatch: got \(bytes.count), expected \(expected)"
            )
        }
        return DecodedRGBAImage(width: width, height: height, pixels: bytes)
    }

    static func decodeR8(
        _ bytes: Data,
        width: Int,
        height: Int,
        mipmap: Int
    ) throws -> DecodedRGBAImage {
        let expected = width * height
        guard bytes.count == expected else {
            throw WPETexDecodeError.decodeFailed(
                mipmap: mipmap,
                detail: "R8 byte count mismatch: got \(bytes.count), expected \(expected)"
            )
        }
        var rgba = Data(count: expected * 4)
        rgba.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                let src = input.bindMemory(to: UInt8.self).baseAddress!
                let dst = out.bindMemory(to: UInt8.self).baseAddress!
                for i in 0..<expected {
                    let r = src[i]
                    dst[i * 4 + 0] = r
                    dst[i * 4 + 1] = r
                    dst[i * 4 + 2] = r
                    dst[i * 4 + 3] = 255
                }
            }
        }
        return DecodedRGBAImage(width: width, height: height, pixels: rgba)
    }

    /// WPE stores two distinct things in `RG88`:
    ///   - Normal maps / data textures (default): R and G independent (e.g.
    ///     normal.xy). Keep (R, G, 0, 255) so shaders reading `.xy`
    ///     (waterripple's `DecompressNormal`) stay correct.
    ///   - Grayscale + alpha glows (`alphaChannelPriority`, TEXI `0x80000`):
    ///     legacy LUMINANCE_ALPHA — R is luminance, G is alpha. Must expand to
    ///     (R, R, R, G) as GL samples LUMINANCE_ALPHA. Light shafts/beams are
    ///     this kind; decoding as (R, G, 0, 255) forced alpha to 1.0, so
    ///     additive sprites stacked at one point saturated the quad into a
    ///     solid block — the "red square light" artifact (scene 3426865175).
    static func decodeRG88(
        _ bytes: Data,
        width: Int,
        height: Int,
        mipmap: Int,
        alphaChannelPriority: Bool = false
    ) throws -> DecodedRGBAImage {
        let expected = width * height * 2
        guard bytes.count == expected else {
            throw WPETexDecodeError.decodeFailed(
                mipmap: mipmap,
                detail: "RG88 byte count mismatch: got \(bytes.count), expected \(expected)"
            )
        }
        let pixelCount = width * height
        var rgba = Data(count: pixelCount * 4)
        rgba.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                let src = input.bindMemory(to: UInt8.self).baseAddress!
                let dst = out.bindMemory(to: UInt8.self).baseAddress!
                for i in 0..<pixelCount {
                    let r = src[i * 2 + 0]
                    let g = src[i * 2 + 1]
                    if alphaChannelPriority {
                        dst[i * 4 + 0] = r
                        dst[i * 4 + 1] = r
                        dst[i * 4 + 2] = r
                        dst[i * 4 + 3] = g
                    } else {
                        dst[i * 4 + 0] = r
                        dst[i * 4 + 1] = g
                        dst[i * 4 + 2] = 0
                        dst[i * 4 + 3] = 255
                    }
                }
            }
        }
        return DecodedRGBAImage(width: width, height: height, pixels: rgba)
    }
}
#endif
