import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPETexMetalTranscoder — GPU-backed BC → RGBA8")
struct WPETexMetalTranscoderTests {

    @Test("isAvailable reports true for every BC format on a Metal device with BC compression support")
    func isAvailableMatchesDeviceCapability() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }
        let supported = device.supportsBCTextureCompression
        for format in [WPETexFormat.dxt1, .dxt3, .dxt5, .bc7] {
            #expect(WPETexMetalTranscoder.isAvailable(for: format) == supported)
        }
    }

    @Test("Non-BC formats route through the pixel decoder and stay unsupported here")
    func nonBCFormatsRemainUnavailable() {
        #expect(!WPETexMetalTranscoder.isAvailable(for: .rgba8888))
        #expect(!WPETexMetalTranscoder.isAvailable(for: .r8))
        #expect(!WPETexMetalTranscoder.isAvailable(for: .rg88))
    }

    @Test("Transcoding a single DXT5 4×4 block produces a 4×4 RGBA8 image")
    func transcodeDXT5SingleBlockReturnsRGBA() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              device.supportsBCTextureCompression else {
            return
        }
        // BC3 (DXT5) = 8-byte alpha block + 8-byte color block. The
        // specific values don't matter for this round-trip shape check;
        // the GPU just needs valid block layout to decompress into a
        // 4×4 pixel tile.
        let block = Data([
            // alpha: a0=0xFF, a1=0x00, 6 bytes of 3-bit indices
            0xFF, 0x00, 0x49, 0x92, 0x24, 0x49, 0x92, 0x24,
            // color: c0=0xFFFF (white), c1=0x0000 (black), 4 bytes of 2-bit indices
            0xFF, 0xFF, 0x00, 0x00, 0x55, 0x55, 0x55, 0x55
        ])
        let decoded = try WPETexMetalTranscoder.transcode(
            block,
            format: .dxt5,
            width: 4,
            height: 4,
            mipmap: 0
        )
        #expect(decoded.width == 4)
        #expect(decoded.height == 4)
        #expect(decoded.pixels.count == 4 * 4 * 4)
    }

    @Test("Transcode rejects formats that aren't BC")
    func transcodeRejectsNonBC() {
        guard let device = MTLCreateSystemDefaultDevice(),
              device.supportsBCTextureCompression else {
            return
        }
        do {
            _ = try WPETexMetalTranscoder.transcode(
                Data(count: 64),
                format: .rgba8888,
                width: 4,
                height: 4,
                mipmap: 0
            )
            Issue.record("Expected unsupportedFormat for rgba8888")
        } catch WPETexDecodeError.unsupportedFormat {
            // ok
        } catch {
            Issue.record("Expected unsupportedFormat, got \(error)")
        }
    }
}
