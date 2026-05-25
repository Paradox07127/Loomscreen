#if !LITE_BUILD
import Metal

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
    /// Maps a WPE texture container format to the concrete `MTLPixelFormat`
    /// the renderer should allocate. Always returns the linear (non-`_srgb`)
    /// variant — WPE shaders are authored against raw RGBA8 math; routing
    /// through `_srgb` variants causes an unwanted sample-time linearise
    /// that doesn't exist on the WPE Windows or Almamu reference renderers.
    static func mapping(
        for format: WPETexFormat,
        capabilities: WPEMetalTextureCapabilities
    ) throws -> WPEMetalTextureFormatMapping {
        switch format {
        case .rgba8888:
            return WPEMetalTextureFormatMapping(pixelFormat: .rgba8Unorm, bytesPerPixel: 4, bytesPerBlock: nil)
        case .r8:
            return WPEMetalTextureFormatMapping(pixelFormat: .r8Unorm, bytesPerPixel: 1, bytesPerBlock: nil)
        case .rg88:
            return WPEMetalTextureFormatMapping(pixelFormat: .rg8Unorm, bytesPerPixel: 2, bytesPerBlock: nil)
        case .dxt1:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(pixelFormat: .bc1_rgba, bytesPerPixel: nil, bytesPerBlock: 8)
        case .dxt3:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(pixelFormat: .bc2_rgba, bytesPerPixel: nil, bytesPerBlock: 16)
        case .dxt5:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(pixelFormat: .bc3_rgba, bytesPerPixel: nil, bytesPerBlock: 16)
        case .bc7:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(pixelFormat: .bc7_rgbaUnorm, bytesPerPixel: nil, bytesPerBlock: 16)
        case .rgba1010102:
            throw WPEMetalTextureLoaderError.unsupportedFormat(format)
        }
    }
}
#endif
