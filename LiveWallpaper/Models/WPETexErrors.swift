import CoreGraphics
import Foundation

/// Wallpaper Engine `.tex` container format codes. Source: community
/// reverse-engineering work in `RePKG` and `linux-wallpaperengine` cross-
/// referenced against the user's Steam Workshop samples (`TEXV0005` /
/// `TEXI0001` / `TEXB0003` is the modal layout).
enum WPETexFormat: Int, Sendable, Equatable {
    case rgba8888 = 0
    case dxt5 = 4   // BC3
    case dxt3 = 6   // BC2
    case dxt1 = 7   // BC1
    case rg88 = 8
    case r8 = 9
    case bc7 = 12
    case rgba1010102 = 13

    /// Bytes per pixel for uncompressed formats; nil for block-compressed
    /// (BC) formats where the unit is a 4×4 block.
    var bytesPerPixel: Int? {
        switch self {
        case .rgba8888, .rgba1010102: return 4
        case .r8: return 1
        case .rg88: return 2
        case .dxt1, .dxt3, .dxt5, .bc7: return nil
        }
    }

    /// 16 for BC1; 32 for BC2/3/7. nil for uncompressed.
    var bytesPerBlock: Int? {
        switch self {
        case .dxt1: return 8
        case .dxt3, .dxt5, .bc7: return 16
        default: return nil
        }
    }

    /// Expected raw byte count for a given mip dimension (no compression
    /// padding). Block-compressed mips round up to multiples of 4.
    func expectedByteCount(width: Int, height: Int) -> Int {
        if let bpp = bytesPerPixel {
            return max(width, 1) * max(height, 1) * bpp
        }
        guard let bpb = bytesPerBlock else { return 0 }
        let blocksW = max((width + 3) / 4, 1)
        let blocksH = max((height + 3) / 4, 1)
        return blocksW * blocksH * bpb
    }

    var debugLabel: String {
        switch self {
        case .rgba8888:    return "RGBA8888"
        case .dxt5:        return "DXT5 (BC3)"
        case .dxt3:        return "DXT3 (BC2)"
        case .dxt1:        return "DXT1 (BC1)"
        case .r8:          return "R8"
        case .rg88:        return "RG88"
        case .rgba1010102: return "RGBA1010102"
        case .bc7:         return "BC7"
        }
    }

    /// True when Phase 2.1 has a decode path that produces a CGImage.
    /// Used by capability tier classification so a known-but-unsupported
    /// format (e.g. RGBA1010102) is correctly counted as unresolvable
    /// instead of optimistically tagged as renderable.
    var isPhase21Decodable: Bool {
        switch self {
        case .rgba8888, .r8, .rg88:
            return true
        case .dxt1, .dxt3, .dxt5, .bc7:
            // Phase 2.1 has a Metal pipeline scaffolded but a real BC →
            // RGBA8 transcode requires a render/compute pass we have not
            // shipped yet (a `blitEncoder.copy` cannot transcode formats).
            // Until that lands, tag BC formats as not-yet-decodable so the
            // import service classifies them as `.unsupportedFormat` with
            // a precise UI message rather than rendering a black layer.
            return false
        case .rgba1010102:
            return false
        }
    }
}

/// Failure modes from `WPETexDecoder`. Each case maps to a precise UI
/// `FallbackReason` so the user sees "Format 13 (BC7) Metal-only" instead
/// of "scene unsupported".
enum WPETexDecodeError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedContainer(magic: String)
    case unsupportedBlock(magic: String)
    case missingInfoBlock
    case missingBitmapBlock
    case unsupportedFormat(code: Int)
    case unsupportedAnimation
    case invalidDimensions(width: Int, height: Int)
    case truncatedBlock(block: String, offset: Int)
    case mipmapOutOfBounds(index: Int)
    case decompressionFailed(mipmap: Int)
    case decodeFailed(mipmap: Int, detail: String)
    case metalUnavailable(format: WPETexFormat)

    var errorDescription: String? {
        switch self {
        case .unsupportedContainer(let magic):
            return ".tex container '\(magic)' is unrecognised."
        case .unsupportedBlock(let magic):
            return ".tex block '\(magic)' is unrecognised."
        case .missingInfoBlock:
            return ".tex file is missing the TEXI info block."
        case .missingBitmapBlock:
            return ".tex file is missing the TEXB bitmap block."
        case .unsupportedFormat(let code):
            return ".tex format code \(code) is not yet supported."
        case .unsupportedAnimation:
            return ".tex animation/sequence frames are not supported."
        case .invalidDimensions(let w, let h):
            return ".tex declares invalid dimensions \(w)×\(h)."
        case .truncatedBlock(let block, let offset):
            return ".tex block '\(block)' truncated at offset \(offset)."
        case .mipmapOutOfBounds(let index):
            return ".tex mipmap index \(index) is out of bounds."
        case .decompressionFailed(let mipmap):
            return ".tex mipmap \(mipmap) decompression failed."
        case .decodeFailed(let mipmap, let detail):
            return ".tex mipmap \(mipmap) decode failed: \(detail)"
        case .metalUnavailable(let format):
            return "Cannot decode \(format.debugLabel) without Metal support on this machine."
        }
    }
}

// MARK: - Value types parsed out of the container

/// `TEXI` block payload. Width / height are in pixels; `mipmapCount`
/// counts the mip chain stored in the following `TEXB` block.
struct WPETexInfo: Sendable, Equatable {
    let containerVersion: Int
    let infoVersion: Int
    let width: Int
    let height: Int
    let textureFormatCode: Int
    let format: WPETexFormat?
    let mipmapCount: Int
    let flags: UInt32

    var dimensionsLooksValid: Bool {
        width > 0 && height > 0
            && width <= 16_384 && height <= 16_384
    }
}

/// One mipmap entry pulled out of `TEXB`. `payload` is the raw stored bytes
/// — may be larger than `expectedByteCount` (uncompressed) or smaller (LZ4-
/// compressed). Decoder reconciles which case it is.
struct WPETexMipmap: Sendable, Equatable {
    let index: Int
    let width: Int
    let height: Int
    let storedByteCount: Int
    let decompressedByteCount: Int?
    let payload: Data
    /// Set when the bitmap header marked this mip as LZ4-compressed (`TEXB`
    /// V3+ exposes the flag explicitly). Drives `WPETexDecoder.inflate`
    /// behaviour: padded raw payloads with a trailing slack get truncated
    /// to the expected byte count instead of misinterpreted as compressed.
    let isCompressed: Bool
}

struct WPETexBitmapBlock: Sendable, Equatable {
    let version: Int
    let sourceImageFormatCode: Int?
    let isVideoPayload: Bool
    let mipmaps: [WPETexMipmap]

    var largestMipmap: WPETexMipmap? {
        mipmaps.first
    }

    var usesEncodedImagePayload: Bool {
        guard let sourceImageFormatCode else { return false }
        return sourceImageFormatCode != -1 && !isVideoPayload
    }
}

/// CPU-side RGBA8 image emitted by every decode path (CPU or Metal). A
/// thin Sendable container so the actual `CGImage` can be created at the
/// resolver boundary.
struct DecodedRGBAImage: Sendable, Equatable {
    let width: Int
    let height: Int
    let pixels: Data

    init(width: Int, height: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

extension DecodedRGBAImage {
    /// Builds a non-premultiplied RGBA8 `CGImage`. Uses
    /// `kCGImageAlphaLast` so SpriteKit's `SKTexture(cgImage:)` reads the
    /// alpha channel correctly without a swizzle pass.
    func makeCGImage() throws -> CGImage {
        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: pixels as CFData) else {
            throw WPETexDecodeError.decodeFailed(mipmap: 0, detail: "CGDataProvider init failed")
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw WPETexDecodeError.decodeFailed(mipmap: 0, detail: "CGImage init failed")
        }
        return image
    }
}
