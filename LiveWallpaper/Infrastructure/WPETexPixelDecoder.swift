#if !LITE_BUILD
import Foundation

/// CPU pixel-decode paths for the uncompressed `.tex` formats. Block-
/// compressed (BC) formats live in `WPETexMetalTranscoder`. Each function
/// returns a `DecodedRGBAImage` with `kCGImageAlphaLast` byte order so the
/// caller can hand it straight to `CGImage` / `SKTexture(cgImage:)`.
enum WPETexPixelDecoder {

    /// Validates the input length and returns the bytes verbatim — WPE's `RGBA8888` is already in the in-memory layout we want.
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

    /// Single-channel red expanded into RGBA(r,r,r,255).
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

    /// Two-channel red+green expanded into RGBA(r,g,0,255).
    static func decodeRG88(
        _ bytes: Data,
        width: Int,
        height: Int,
        mipmap: Int
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
                    dst[i * 4 + 0] = src[i * 2 + 0]
                    dst[i * 4 + 1] = src[i * 2 + 1]
                    dst[i * 4 + 2] = 0
                    dst[i * 4 + 3] = 255
                }
            }
        }
        return DecodedRGBAImage(width: width, height: height, pixels: rgba)
    }
}
#endif
