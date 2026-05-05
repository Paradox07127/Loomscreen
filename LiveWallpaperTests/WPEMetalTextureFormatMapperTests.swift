import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal texture format mapper")
struct WPEMetalTextureFormatMapperTests {

    @Test("Maps CPU-decodable formats to direct Metal pixel formats")
    func mapsUncompressedFormats() throws {
        let capabilities = WPEMetalTextureCapabilities(supportsBCTextureCompression: false)

        #expect(try WPEMetalTextureFormatMapper.mapping(for: .rgba8888, capabilities: capabilities).pixelFormat == .rgba8Unorm)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .r8, capabilities: capabilities).pixelFormat == .r8Unorm)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .rg88, capabilities: capabilities).pixelFormat == .rg8Unorm)
    }

    @Test("Maps BC formats to native compressed Metal formats when supported")
    func mapsBCFormatsWhenSupported() throws {
        let capabilities = WPEMetalTextureCapabilities(supportsBCTextureCompression: true)

        #expect(try WPEMetalTextureFormatMapper.mapping(for: .dxt1, capabilities: capabilities).pixelFormat == .bc1_rgba)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .dxt3, capabilities: capabilities).pixelFormat == .bc2_rgba)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .dxt5, capabilities: capabilities).pixelFormat == .bc3_rgba)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .bc7, capabilities: capabilities).pixelFormat == .bc7_rgbaUnorm)
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
