import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal texture format mapper")
struct WPEMetalTextureFormatMapperTests {

    @Test("Defaults to sRGB pixel formats for color textures")
    func defaultsToSRGBForColorFormats() throws {
        let capabilities = WPEMetalTextureCapabilities(supportsBCTextureCompression: true)

        #expect(try WPEMetalTextureFormatMapper.mapping(for: .rgba8888, capabilities: capabilities).pixelFormat == .rgba8Unorm_srgb)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .dxt1, capabilities: capabilities).pixelFormat == .bc1_rgba_srgb)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .dxt3, capabilities: capabilities).pixelFormat == .bc2_rgba_srgb)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .dxt5, capabilities: capabilities).pixelFormat == .bc3_rgba_srgb)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .bc7, capabilities: capabilities).pixelFormat == .bc7_rgbaUnorm_srgb)
    }

    @Test("Linear color space maps to non-sRGB variants")
    func linearColorSpaceUsesUnormVariants() throws {
        let capabilities = WPEMetalTextureCapabilities(supportsBCTextureCompression: true)

        #expect(try WPEMetalTextureFormatMapper.mapping(for: .rgba8888, capabilities: capabilities, colorSpace: .linear).pixelFormat == .rgba8Unorm)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .dxt1, capabilities: capabilities, colorSpace: .linear).pixelFormat == .bc1_rgba)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .bc7, capabilities: capabilities, colorSpace: .linear).pixelFormat == .bc7_rgbaUnorm)
    }

    @Test("Single-channel data formats stay linear regardless of colorSpace")
    func singleChannelStaysLinear() throws {
        let capabilities = WPEMetalTextureCapabilities(supportsBCTextureCompression: false)

        #expect(try WPEMetalTextureFormatMapper.mapping(for: .r8, capabilities: capabilities).pixelFormat == .r8Unorm)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .rg88, capabilities: capabilities).pixelFormat == .rg8Unorm)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .r8, capabilities: capabilities, colorSpace: .sRGB).pixelFormat == .r8Unorm)
    }

    @Test("Fails closed for BC formats when device support is absent")
    func rejectsBCWhenUnsupported() {
        let capabilities = WPEMetalTextureCapabilities(supportsBCTextureCompression: false)

        #expect(throws: WPEMetalTextureLoaderError.unsupportedCompressedFormat(.bc7)) {
            _ = try WPEMetalTextureFormatMapper.mapping(for: .bc7, capabilities: capabilities)
        }
    }

    @Test("Rejects RGBA1010102 until a concrete sampling path exists")
    func rejectsRGBA1010102() {
        let capabilities = WPEMetalTextureCapabilities(supportsBCTextureCompression: true)

        #expect(throws: WPEMetalTextureLoaderError.unsupportedFormat(.rgba1010102)) {
            _ = try WPEMetalTextureFormatMapper.mapping(for: .rgba1010102, capabilities: capabilities)
        }
    }
}
