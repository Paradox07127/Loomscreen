import CoreGraphics
import Foundation

/// Wallpaper Engine `.tex` container format codes. Source: community
/// reverse-engineering work in `RePKG` and `linux-wallpaperengine` cross-
/// referenced against the user's Steam Workshop samples (`TEXV0005` /
/// `TEXI0001` / `TEXB0003` is the modal layout).
public enum WPETexFormat: Int, Sendable, Equatable {
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
    public var bytesPerPixel: Int? {
        switch self {
        case .rgba8888, .rgba1010102: return 4
        case .r8: return 1
        case .rg88: return 2
        case .dxt1, .dxt3, .dxt5, .bc7: return nil
        }
    }

    /// 16 for BC1; 32 for BC2/3/7. nil for uncompressed.
    public var bytesPerBlock: Int? {
        switch self {
        case .dxt1: return 8
        case .dxt3, .dxt5, .bc7: return 16
        default: return nil
        }
    }

    /// Expected raw byte count for a given mip dimension (no compression padding).
    public func expectedByteCount(width: Int, height: Int) -> Int {
        if let bpp = bytesPerPixel {
            return max(width, 1) * max(height, 1) * bpp
        }
        guard let bpb = bytesPerBlock else { return 0 }
        let blocksW = max((width + 3) / 4, 1)
        let blocksH = max((height + 3) / 4, 1)
        return blocksW * blocksH * bpb
    }

    public var debugLabel: String {
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

    public var isPhase21Decodable: Bool {
        switch self {
        case .rgba8888, .r8, .rg88:
            return true
        case .dxt1, .dxt3, .dxt5, .bc7:
            return false
        case .rgba1010102:
            return false
        }
    }
}

/// Failure modes from `WPETexDecoder`. Each case maps to a precise UI
/// `FallbackReason` so the user sees "Format 13 (BC7) Metal-only" instead
/// of "scene unsupported".
public enum WPETexDecodeError: Error, Equatable, Sendable, LocalizedError {
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

    public var errorDescription: String? {
        switch self {
        case .unsupportedContainer(let magic):
            return String(localized: "error.texture.decode.unsupported_container", defaultValue: ".tex container '\(magic)' is unrecognised.", comment: "Error shown when a Wallpaper Engine .tex container magic is unsupported.")
        case .unsupportedBlock(let magic):
            return String(localized: "error.texture.decode.unsupported_block", defaultValue: ".tex block '\(magic)' is unrecognised.", comment: "Error shown when a Wallpaper Engine .tex block magic is unsupported.")
        case .missingInfoBlock:
            return String(localized: "error.texture.decode.missing_info_block", defaultValue: ".tex file is missing the TEXI info block.", comment: "Error shown when a Wallpaper Engine .tex file is missing the TEXI block.")
        case .missingBitmapBlock:
            return String(localized: "error.texture.decode.missing_bitmap_block", defaultValue: ".tex file is missing the TEXB bitmap block.", comment: "Error shown when a Wallpaper Engine .tex file is missing the TEXB block.")
        case .unsupportedFormat(let code):
            return String(localized: "error.texture.decode.unsupported_format", defaultValue: ".tex format code \(code) is not yet supported.", comment: "Error shown when a Wallpaper Engine .tex file uses an unsupported format code.")
        case .unsupportedAnimation:
            return String(localized: "error.texture.decode.unsupported_animation", defaultValue: ".tex animation/sequence frames are not supported.", comment: "Error shown when a Wallpaper Engine .tex file contains unsupported animation frames.")
        case .invalidDimensions(let w, let h):
            return String(localized: "error.texture.decode.invalid_dimensions", defaultValue: ".tex declares invalid dimensions \(w)×\(h).", comment: "Error shown when a Wallpaper Engine .tex file declares invalid pixel dimensions.")
        case .truncatedBlock(let block, let offset):
            return String(localized: "error.texture.decode.truncated_block", defaultValue: ".tex block '\(block)' truncated at offset \(offset).", comment: "Error shown when a Wallpaper Engine .tex block ends before its declared payload.")
        case .mipmapOutOfBounds(let index):
            return String(localized: "error.texture.decode.mipmap_out_of_bounds", defaultValue: ".tex mipmap index \(index) is out of bounds.", comment: "Error shown when a Wallpaper Engine .tex mipmap index is invalid.")
        case .decompressionFailed(let mipmap):
            return String(localized: "error.texture.decode.decompression_failed", defaultValue: ".tex mipmap \(mipmap) decompression failed.", comment: "Error shown when a Wallpaper Engine .tex mipmap cannot be decompressed.")
        case .decodeFailed(let mipmap, let detail):
            return String(localized: "error.texture.decode.decode_failed", defaultValue: ".tex mipmap \(mipmap) decode failed: \(detail)", comment: "Error shown when a Wallpaper Engine .tex mipmap cannot be decoded.")
        case .metalUnavailable(let format):
            return String(localized: "error.texture.decode.metal_unavailable", defaultValue: "Cannot decode \(format.debugLabel) without Metal support on this machine.", comment: "Error shown when a texture format requires Metal support that is unavailable.")
        }
    }
}

// MARK: - Value types parsed out of the container

/// `TEXI` block payload. Width / height are in pixels; `mipmapCount`
/// counts the mip chain stored in the following `TEXB` block.
public struct WPETexInfo: Sendable, Equatable {
    public let containerVersion: Int
    public let infoVersion: Int
    public let width: Int
    public let height: Int
    public let textureFormatCode: Int
    public let format: WPETexFormat?
    public let mipmapCount: Int
    public let flags: UInt32

    public init(containerVersion: Int, infoVersion: Int, width: Int, height: Int, textureFormatCode: Int, format: WPETexFormat?, mipmapCount: Int, flags: UInt32) {
        self.containerVersion = containerVersion
        self.infoVersion = infoVersion
        self.width = width
        self.height = height
        self.textureFormatCode = textureFormatCode
        self.format = format
        self.mipmapCount = mipmapCount
        self.flags = flags
    }

    public var dimensionsLooksValid: Bool {
        width > 0 && height > 0
            && width <= 16_384 && height <= 16_384
    }
}

/// One mipmap entry pulled out of `TEXB`.
public struct WPETexMipmap: Sendable, Equatable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let storedByteCount: Int
    public let decompressedByteCount: Int?
    public let payload: Data
    public let isCompressed: Bool

    public init(index: Int, width: Int, height: Int, storedByteCount: Int, decompressedByteCount: Int?, payload: Data, isCompressed: Bool) {
        self.index = index
        self.width = width
        self.height = height
        self.storedByteCount = storedByteCount
        self.decompressedByteCount = decompressedByteCount
        self.payload = payload
        self.isCompressed = isCompressed
    }
}

public struct WPETexBitmapBlock: Sendable, Equatable {
    public let version: Int
    public let sourceImageFormatCode: Int?
    public let isVideoPayload: Bool
    public let frames: [[WPETexMipmap]]

    public init(version: Int, sourceImageFormatCode: Int?, isVideoPayload: Bool, frames: [[WPETexMipmap]]) {
        self.version = version
        self.sourceImageFormatCode = sourceImageFormatCode
        self.isVideoPayload = isVideoPayload
        self.frames = frames
    }

    public var mipmaps: [WPETexMipmap] {
        frames.first ?? []
    }

    public var largestMipmap: WPETexMipmap? {
        mipmaps.first
    }

    public var usesEncodedImagePayload: Bool {
        guard let sourceImageFormatCode else { return false }
        return sourceImageFormatCode != -1 && !isVideoPayload
    }
}

public struct WPETexAnimationTrack: Sendable, Equatable {
    public static let defaultFrameRate: Double = 25

    public let frames: [WPETexAnimationFrame]
    public let frameRate: Double
    public let loop: Bool

    public init(frames: [WPETexAnimationFrame], frameRate: Double, loop: Bool) {
        self.frames = frames
        self.frameRate = frameRate
        self.loop = loop
    }

    public var frameCount: Int { frames.count }
}

public struct WPETexAnimationFrame: Sendable, Equatable {
    public let imageID: Int
    public let duration: TimeInterval
    public let mipmaps: [WPETexTextureMipmap]
    /// Source-image sub-rect this animation frame maps to. `nil` means
    /// "use the whole image" (legacy/back-compat for `.tex` files that
    /// omit a TEXS block).
    public let subRect: CGRect?

    public init(
        imageID: Int,
        duration: TimeInterval,
        mipmaps: [WPETexTextureMipmap],
        subRect: CGRect? = nil
    ) {
        self.imageID = imageID
        self.duration = duration
        self.mipmaps = mipmaps
        self.subRect = subRect
    }
}

/// Single mipmap level held in its on-disk compressed form. The lazy
/// streaming source decompresses these on demand so the runtime never
/// materializes every animation frame upfront.
public struct WPETexCompressedMipmap: Sendable, Equatable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let isCompressed: Bool
    public let compressedBytes: Data
    public let decompressedByteCount: Int

    public init(
        index: Int,
        width: Int,
        height: Int,
        isCompressed: Bool,
        compressedBytes: Data,
        decompressedByteCount: Int
    ) {
        self.index = index
        self.width = width
        self.height = height
        self.isCompressed = isCompressed
        self.compressedBytes = compressedBytes
        self.decompressedByteCount = decompressedByteCount
    }
}

public struct WPETexCompressedImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let payloads: [WPETexCompressedMipmap]

    public init(width: Int, height: Int, payloads: [WPETexCompressedMipmap]) {
        self.width = width
        self.height = height
        self.payloads = payloads
    }
}

public struct WPETexStreamingFrame: Sendable, Equatable {
    public let imageID: Int
    public let subRect: CGRect
    public let duration: TimeInterval

    public init(imageID: Int, subRect: CGRect, duration: TimeInterval) {
        self.imageID = imageID
        self.subRect = subRect
        self.duration = duration
    }
}

/// Lazy-decode counterpart to `WPETexTexturePayload`. Holds compressed
/// per-image bytes plus the TEXS sub-rect schedule; consumers stream
/// frames out one at a time, keeping a small LRU cache of recently
/// decompressed images resident in RAM (consumer-controlled — see
/// `WPETexLazyAnimatedTextureSource.decompressedImageCacheCapacity`).
/// Peak CPU footprint is therefore the compressed `.tex` file size plus
/// `cacheCapacity × image-bytes`, not the full eager-decode total.
public struct WPETexStreamingPayload: Sendable, Equatable {
    public let info: WPETexInfo
    public let compressedImages: [WPETexCompressedImage]
    public let frames: [WPETexStreamingFrame]
    public let frameRate: Double
    public let loop: Bool

    public init(
        info: WPETexInfo,
        compressedImages: [WPETexCompressedImage],
        frames: [WPETexStreamingFrame],
        frameRate: Double,
        loop: Bool
    ) {
        self.info = info
        self.compressedImages = compressedImages
        self.frames = frames
        self.frameRate = frameRate
        self.loop = loop
    }

    /// Decision input for `WPEMetalSceneRenderer`: route to the lazy
    /// source when the eager raw-bytes footprint would exceed budget.
    public var totalUncompressedImageBytes: Int {
        compressedImages.reduce(0) { total, image in
            total + (image.payloads.first?.decompressedByteCount
                ?? max(image.width, 1) * max(image.height, 1) * 4)
        }
    }
}

public struct WPETexVideoPayload: Sendable, Equatable {
    public let bytes: Data
    public let fileExtension: String

    public init(bytes: Data, fileExtension: String = "mp4") {
        self.bytes = bytes
        self.fileExtension = fileExtension
    }
}

public struct WPETexTexturePayload: Sendable, Equatable {
    public let info: WPETexInfo
    public let mipmaps: [WPETexTextureMipmap]
    public let animationTrack: WPETexAnimationTrack?
    public let videoPayload: WPETexVideoPayload?

    private let explicitAnimationFlag: Bool

    public init(
        info: WPETexInfo,
        mipmaps: [WPETexTextureMipmap],
        hasAnimationFrames: Bool,
        animationTrack: WPETexAnimationTrack? = nil,
        videoPayload: WPETexVideoPayload? = nil
    ) {
        self.info = info
        self.mipmaps = mipmaps
        self.explicitAnimationFlag = hasAnimationFrames
        self.animationTrack = animationTrack
        self.videoPayload = videoPayload
    }

    public var hasAnimationFrames: Bool {
        explicitAnimationFlag || animationTrack != nil
    }

    public var largestMipmap: WPETexTextureMipmap? {
        mipmaps.first
    }
}

public struct WPETexTextureMipmap: Sendable, Equatable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let bytes: Data

    public init(index: Int, width: Int, height: Int, bytes: Data) {
        self.index = index
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

/// CPU-side RGBA8 image emitted by every decode path (CPU or Metal).
public struct DecodedRGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: Data

    public init(width: Int, height: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

extension DecodedRGBAImage {
    /// Builds a non-premultiplied RGBA8 `CGImage`.
    public func makeCGImage() throws -> CGImage {
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
