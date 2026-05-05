import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal texture loader")
struct WPEMetalTextureLoaderTests {

    @Test("Uploads RGBA texture payload into an MTLTexture")
    func uploadsRGBA8888Payload() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bytes = Data([
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255
        ])
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 2,
                height: 2,
                textureFormatCode: WPETexFormat.rgba8888.rawValue,
                format: .rgba8888,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 2, height: 2, bytes: bytes)],
            hasAnimationFrames: false
        )

        let texture = try WPEMetalTextureLoader(device: device).makeTexture(from: payload, label: "test-rgba")

        #expect(texture.width == 2)
        #expect(texture.height == 2)
        // Phase 2A H3: payloads default to sRGB so the gamma matches the
        // SpriteKit/CGImage fallback. Linear uploads must be opted into.
        #expect(texture.pixelFormat == .rgba8Unorm_srgb)
    }

    @Test("Rejects BC payload when current device cannot sample BC")
    func rejectsBCWithoutDeviceSupport() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 4,
                height: 4,
                textureFormatCode: WPETexFormat.bc7.rawValue,
                format: .bc7,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 4, height: 4, bytes: Data(count: 16))],
            hasAnimationFrames: false
        )
        let loader = WPEMetalTextureLoader(
            device: device,
            capabilities: WPEMetalTextureCapabilities(supportsBCTextureCompression: false)
        )

        #expect(throws: WPEMetalTextureLoaderError.unsupportedCompressedFormat(.bc7)) {
            _ = try loader.makeTexture(from: payload, label: "test-bc7")
        }
    }
}
