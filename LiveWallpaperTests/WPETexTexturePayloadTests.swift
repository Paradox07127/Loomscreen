import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LiveWallpaper

@Suite("WPETexDecoder texture payload extraction")
struct WPETexTexturePayloadTests {

    @Test("Bridges TEXB-encoded PNG payload to RGBA8888 for Metal upload")
    func bridgesEncodedPNGPayloadToRGBA8888() throws {
        // Synthesise a 4×4 solid-red PNG, wrap it as a WPE .tex file whose
        // TEXB block declares an encoded image payload. Before the bridge
        // this returned .unsupportedFormat(code: 0) — the failure mode
        // that blocked ~80% of workshop scenes in the Phase A.3 corpus
        // baseline.
        let png = try makeSolidColorPNG(width: 4, height: 4, red: 255, green: 0, blue: 0, alpha: 255)
        let tex = makeImage(
            width: 4,
            height: 4,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: png,
            sourceImageFormatCode: 0
        )

        let extracted = try WPETexDecoder().extractTexturePayload(data: tex).get()

        #expect(extracted.info.format == .rgba8888)
        let mip = try #require(extracted.largestMipmap)
        #expect(mip.width == 4)
        #expect(mip.height == 4)
        #expect(mip.bytes.count == 4 * 4 * 4)
        // First pixel should be opaque red after rasterisation.
        let firstPixel = Array(mip.bytes.prefix(4))
        #expect(firstPixel[0] == 0xFF, "R channel should be 0xFF for the solid-red fixture")
        #expect(firstPixel[3] == 0xFF, "A channel should be 0xFF for the solid-red fixture")
    }

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

    @Test("Routes MP4-backed TEX payloads to the videoPayload field")
    func extractsVideoPayloadFromMP4Tex() throws {
        let mp4 = mp4HeaderPayload()
        let tex = makeImage(
            width: 1,
            height: 1,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: mp4
        )

        // Phase 2E: MP4-in-TEX is no longer fail-closed on the Metal payload
        // path. The renderer hands the bytes to `WPEVideoTextureSource`.
        let extracted = try WPETexDecoder().extractTexturePayload(data: tex).get()

        let video = try #require(extracted.videoPayload)
        #expect(video.bytes == mp4)
        #expect(extracted.animationTrack == nil)
        #expect(extracted.mipmaps.isEmpty)
    }

    private func makeImage(
        width: Int,
        height: Int,
        formatCode: Int,
        payload: Data,
        isLZ4Compressed: Bool = false,
        decompressedByteCount: Int? = nil,
        sourceImageFormatCode: Int = -1
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
        appendInt32(&buffer, Int32(sourceImageFormatCode))
        appendInt32(&buffer, 1)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendUInt32(&buffer, isLZ4Compressed ? 1 : 0)
        appendUInt32(&buffer, UInt32(decompressedByteCount ?? payload.count))
        appendUInt32(&buffer, UInt32(payload.count))
        buffer.append(payload)
        return buffer
    }

    private func makeSolidColorPNG(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8
    ) throws -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * bytesPerPixel
                    base[offset]     = red
                    base[offset + 1] = green
                    base[offset + 2] = blue
                    base[offset + 3] = alpha
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = pixels.withUnsafeMutableBytes { buffer -> CGContext? in
            guard let base = buffer.baseAddress else { return nil }
            return CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        }
        guard let context, let cgImage = context.makeImage() else {
            throw NSError(domain: "WPETexTexturePayloadTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not synthesise CGImage fixture"])
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "WPETexTexturePayloadTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination"])
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "WPETexTexturePayloadTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "PNG finalisation failed"])
        }
        return output as Data
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
