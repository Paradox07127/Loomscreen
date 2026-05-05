import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPETexDecoder texture payload extraction")
struct WPETexTexturePayloadTests {

    @Test("Extracts raw RGBA8888 mip payload without creating CGImage")
    func extractsRGBA8888Payload() throws {
        let payload = Data(repeating: 0xaa, count: 4 * 4 * 4)
        let tex = makeImage(
            width: 4,
            height: 4,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: payload
        )

        let extracted = try WPETexDecoder().extractTexturePayload(data: tex).get()

        #expect(extracted.info.format == .rgba8888)
        #expect(extracted.largestMipmap?.bytes == payload)
        #expect(extracted.largestMipmap?.width == 4)
        #expect(extracted.largestMipmap?.height == 4)
    }

    @Test("Extracts BC7 payload for native Metal sampling")
    func extractsBC7Payload() throws {
        let payload = Data(repeating: 0x3f, count: WPETexFormat.bc7.expectedByteCount(width: 4, height: 4))
        let tex = makeImage(
            width: 4,
            height: 4,
            formatCode: WPETexFormat.bc7.rawValue,
            payload: payload
        )

        let extracted = try WPETexDecoder().extractTexturePayload(data: tex).get()

        #expect(extracted.info.format == .bc7)
        #expect(extracted.largestMipmap?.bytes == payload)
        #expect(extracted.hasAnimationFrames == false)
    }

    @Test("Rejects MP4-backed TEX payloads for Metal texture upload")
    func rejectsVideoPayload() {
        let tex = makeImage(
            width: 1,
            height: 1,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: mp4HeaderPayload()
        )

        let result = WPETexDecoder().extractTexturePayload(data: tex)

        #expect(throws: WPETexDecodeError.unsupportedAnimation) {
            _ = try result.get()
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        formatCode: Int,
        payload: Data,
        isLZ4Compressed: Bool = false,
        decompressedByteCount: Int? = nil
    ) -> Data {
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0001")
        appendInt32(&buffer, Int32(formatCode))
        appendUInt32(&buffer, 0)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendInt32(&buffer, 0)

        appendMagic(&buffer, magic: "TEXB0003")
        appendInt32(&buffer, 1)
        appendInt32(&buffer, -1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendUInt32(&buffer, isLZ4Compressed ? 1 : 0)
        appendUInt32(&buffer, UInt32(decompressedByteCount ?? payload.count))
        appendUInt32(&buffer, UInt32(payload.count))
        buffer.append(payload)
        return buffer
    }

    private func mp4HeaderPayload() -> Data {
        Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x6d, 0x70, 0x34, 0x32,
            0x00, 0x00, 0x00, 0x00
        ])
    }

    private func appendMagic(_ data: inout Data, magic: String) {
        data.append(contentsOf: magic.utf8)
        data.append(0x00)
    }

    private func appendInt32(_ data: inout Data, _ value: Int32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
