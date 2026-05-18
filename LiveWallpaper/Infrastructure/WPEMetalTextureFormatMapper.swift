#if !LITE_BUILD
import Metal

/// Color-space intent for a Metal texture upload. Phase 2A H3 introduces this
/// so the renderer can request sRGB-encoded pixel formats — matching the
/// SpriteKit/CGImage fallback path — while data textures (masks, normal maps,
/// future R8/RG8 channels) stay linear.
enum WPEMetalColorSpace: Equatable, Sendable {
    case sRGB
    case linear
}

struct WPEMetalTextureCapabilities: Equatable, Sendable {
    let supportsBCTextureCompression: Bool

    init(device: MTLDevice) {
        supportsBCTextureCompression = device.supportsBCTextureCompression
    }

    init(supportsBCTextureCompression: Bool) {
        self.supportsBCTextureCompression = supportsBCTextureCompression
    }
}

struct WPEMetalTextureFormatMapping: Equatable, Sendable {
    let pixelFormat: MTLPixelFormat
    let bytesPerPixel: Int?
    let bytesPerBlock: Int?
}

enum WPEMetalTextureLoaderError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormat(WPETexFormat)
    case unsupportedCompressedFormat(WPETexFormat)
    case malformedPayload(String)
    case textureAllocationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return String(
                localized: "error.texture.format.unsupported_format",
                defaultValue: "WPE Metal texture format is unsupported: \(format.debugLabel)",
                comment: "Error shown when a Wallpaper Engine texture format cannot be mapped to Metal."
            )
        case .unsupportedCompressedFormat(let format):
            return String(
                localized: "error.texture.format.unsupported_compressed_format",
                defaultValue: "This Metal device cannot sample \(format.debugLabel) textures.",
                comment: "Error shown when the current Metal device cannot sample a compressed texture format."
            )
        case .malformedPayload(let reason):
            return String(
                localized: "error.texture.format.malformed_payload",
                defaultValue: "WPE Metal texture payload is malformed: \(reason)",
                comment: "Error shown when a Wallpaper Engine texture payload is malformed."
            )
        case .textureAllocationFailed:
            return String(
                localized: "error.texture.format.texture_allocation_failed",
                defaultValue: "Metal texture allocation failed.",
                comment: "Error shown when Metal texture allocation fails."
            )
        }
    }
}

enum WPEMetalTextureFormatMapper {
    /// Maps a WPE texture container format to the concrete `MTLPixelFormat` the renderer should allocate.
    static func mapping(
        for format: WPETexFormat,
        capabilities: WPEMetalTextureCapabilities,
        colorSpace: WPEMetalColorSpace = .sRGB
    ) throws -> WPEMetalTextureFormatMapping {
        switch format {
        case .rgba8888:
            return WPEMetalTextureFormatMapping(
                pixelFormat: colorSpace == .sRGB ? .rgba8Unorm_srgb : .rgba8Unorm,
                bytesPerPixel: 4,
                bytesPerBlock: nil
            )
        case .r8:
            return WPEMetalTextureFormatMapping(pixelFormat: .r8Unorm, bytesPerPixel: 1, bytesPerBlock: nil)
        case .rg88:
            return WPEMetalTextureFormatMapping(pixelFormat: .rg8Unorm, bytesPerPixel: 2, bytesPerBlock: nil)
        case .dxt1:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(
                pixelFormat: colorSpace == .sRGB ? .bc1_rgba_srgb : .bc1_rgba,
                bytesPerPixel: nil,
                bytesPerBlock: 8
            )
        case .dxt3:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(
                pixelFormat: colorSpace == .sRGB ? .bc2_rgba_srgb : .bc2_rgba,
                bytesPerPixel: nil,
                bytesPerBlock: 16
            )
        case .dxt5:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(
                pixelFormat: colorSpace == .sRGB ? .bc3_rgba_srgb : .bc3_rgba,
                bytesPerPixel: nil,
                bytesPerBlock: 16
            )
        case .bc7:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(
                pixelFormat: colorSpace == .sRGB ? .bc7_rgbaUnorm_srgb : .bc7_rgbaUnorm,
                bytesPerPixel: nil,
                bytesPerBlock: 16
            )
        case .rgba1010102:
            throw WPEMetalTextureLoaderError.unsupportedFormat(format)
        }
    }
}
#endif
