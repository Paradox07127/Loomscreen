import Compression
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LiveWallpaper

@Suite("WPETexDecoder — container + RGBA8888")
struct WPETexDecoderTests {

    // MARK: - Container guards

    @Test("Empty data fails with truncatedBlock at offset 0")
    func emptyDataTruncated() {
        let result = WPETexDecoder().decode(data: Data())
        guard case .failure(.truncatedBlock(_, let offset)) = result else {
            Issue.record("Expected truncatedBlock failure, got \(result)")
            return
        }
        #expect(offset == 0)
    }

    @Test("RG88 alphaChannelPriority expands to luminance+alpha (R,R,R,G)")
    func rg88AlphaChannelPriorityExpandsToLuminanceAlpha() throws {
        // Two pixels: (R=200, G=50) and (R=10, G=255).
        let input = Data([200, 50, 10, 255])

        // Default (normal-map style): independent channels, opaque.
        let normal = try WPETexPixelDecoder.decodeRG88(input, width: 2, height: 1, mipmap: 0)
        #expect(
            Array(normal.pixels) == [200, 50, 0, 255, 10, 255, 0, 255],
            "default RG88 must stay (R, G, 0, 255) so normal maps read .xy correctly"
        )

        // Alpha-channel-priority (light glow): LUMINANCE_ALPHA → (R, R, R, G).
        // This is the fix for the "red square light" artifact: the glow's
        // falloff lives in G (alpha), not a forced 255.
        let glow = try WPETexPixelDecoder.decodeRG88(
            input, width: 2, height: 1, mipmap: 0, alphaChannelPriority: true
        )
        #expect(
            Array(glow.pixels) == [200, 200, 200, 50, 10, 10, 10, 255],
            "alphaChannelPriority RG88 must expand to (R, R, R, G) = luminance + alpha"
        )
    }

    @Test("Unknown container magic surfaces unsupportedContainer")
    func unknownContainerMagic() {
        var buffer = Data()
        appendMagic(&buffer, magic: "FAKE9999")
        let result = WPETexDecoder().decode(data: buffer)
        guard case .failure(.unsupportedContainer(let magic)) = result else {
            Issue.record("Expected unsupportedContainer, got \(result)")
            return
        }
        #expect(magic.hasPrefix("FAKE"))
    }

    @Test("Container without TEXI block fails with missingInfoBlock")
    func missingInfoBlock() {
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        let result = WPETexDecoder().decode(data: buffer)
        guard case .failure(.missingInfoBlock) = result else {
            Issue.record("Expected missingInfoBlock, got \(result)")
            return
        }
    }

    @Test("Non-TEXI second block fails with unsupportedBlock")
    func unsupportedSecondBlock() {
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "WHAT0001")
        let result = WPETexDecoder().decode(data: buffer)
        guard case .failure(.unsupportedBlock(let magic)) = result else {
            Issue.record("Expected unsupportedBlock, got \(result)")
            return
        }
        #expect(magic.hasPrefix("WHAT"))
    }

    @Test("Probe of a complete RGBA8888 file yields valid info")
    func probeReturnsInfo() {
        let buffer = makeRGBA8888TestImage(width: 4, height: 4)
        let result = WPETexDecoder().probe(data: buffer)
        guard case .success(let info) = result else {
            Issue.record("Expected probe success, got \(result)")
            return
        }
        #expect(info.width == 4)
        #expect(info.height == 4)
        #expect(info.format == .rgba8888)
        #expect(info.containerVersion == 5)
    }

    // MARK: - RGBA8888 round-trip

    @Test("Decode of synthetic RGBA8888 returns a CGImage with correct dimensions")
    func decodeRGBA8888RoundTrip() throws {
        let buffer = makeRGBA8888TestImage(width: 4, height: 4)
        let result = WPETexDecoder().decode(data: buffer)
        guard case .success(let image) = result else {
            Issue.record("Expected decode success, got \(result)")
            return
        }
        #expect(image.width == 4)
        #expect(image.height == 4)
    }

    // Single-frame static `.tex` (util/black, util/clouds_256, mask textures
    // on saber 3526278753) carry one image and no TEXS schedule. They decode
    // through the eager static path at full resolution; the lazy *streaming*
    // path declines them with `unsupportedAnimation` by design (lazy = animated
    // only). That benign decline must not be mistaken for a decode failure —
    // see `WPEResolutionDiagnosticsTests` for the resolution-summary contract.
    @Test("Single-frame static .tex decodes eagerly at full size and declines the streaming path")
    func singleFrameStaticDecodesEagerlyAndDeclinesStreaming() throws {
        let buffer = makeRGBA8888TestImage(width: 256, height: 256)

        let eager = try WPETexDecoder().extractTexturePayload(data: buffer).get()
        #expect(eager.info.format == .rgba8888)
        #expect(eager.hasAnimationFrames == false)
        #expect(eager.animationTrack == nil)
        #expect(eager.videoPayload == nil)
        let mip = try #require(eager.largestMipmap)
        #expect(mip.width == 256)
        #expect(mip.height == 256)
        #expect(mip.bytes.count == 256 * 256 * 4)

        let streaming = WPETexDecoder().extractStreamingPayload(data: buffer)
        guard case .failure(.unsupportedAnimation) = streaming else {
            Issue.record("Expected single-frame static to decline streaming with unsupportedAnimation, got \(streaming)")
            return
        }
    }

    @Test("Decode accepts RePKG TEXB0003 PNG-backed texture")
    func decodeRePKGTEXB0003PNGBackedTexture() throws {
        let buffer = makeRePKGPNGBackedImage()
        let result = WPETexDecoder().decode(data: buffer)
        guard case .success(let image) = result else {
            Issue.record("Expected decode success for RePKG layout, got \(result)")
            return
        }

        #expect(image.width == 1)
        #expect(image.height == 1)
    }

    @Test("Unknown format code surfaces unsupportedFormat with the offending code")
    func unsupportedFormatCode() {
        let buffer = makeImage(width: 2, height: 2, formatCode: 99, payload: Data(count: 16))
        let result = WPETexDecoder().decode(data: buffer)
        guard case .failure(.unsupportedFormat(let code)) = result else {
            Issue.record("Expected unsupportedFormat, got \(result)")
            return
        }
        #expect(code == 99)
    }

    @Test("LZ4-compressed mip payload decompresses to the expected uncompressed size")
    func lz4InflateOnSizeMismatch() throws {
        let width = 4
        let height = 4
        let raw = Data((0..<(width * height * 4)).map { UInt8(($0 * 7) & 0xff) })
        let compressed = try lz4RawCompress(raw)
        try #require(compressed.count != raw.count,
                     "LZ4 must yield a different byte count to exercise the inflate fallback")

        let buffer = makeImage(
            width: width,
            height: height,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: compressed,
            isLZ4Compressed: true,
            decompressedByteCount: raw.count
        )

        let result = WPETexDecoder().decode(data: buffer)
        guard case .success(let image) = result else {
            Issue.record("Expected decode success after LZ4 inflate, got \(result)")
            return
        }
        #expect(image.width == width)
        #expect(image.height == height)
    }

    @Test("MP4-backed TEXB payload is rejected instead of decoded as raw RGBA")
    func mp4PayloadIsUnsupportedAnimation() {
        let buffer = makeImage(
            width: 1,
            height: 1,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: mp4HeaderPayload()
        )

        let result = WPETexDecoder().decode(data: buffer)
        guard case .failure(.unsupportedAnimation) = result else {
            Issue.record("Expected unsupportedAnimation for MP4-backed TEXB payload, got \(result)")
            return
        }
    }

    // P1: encoded PNG/JPEG + TEXS animation no longer rejects;
    // bridgeEncodedAnimatedImagePayload should produce a usable
    // animation track that shares the ImageIO-rasterized atlas across
    // every TEXS frame, with each frame carrying its own sub-rect.
    @Test("Encoded PNG + TEXS animation extracts an animation track with per-frame sub-rects")
    func encodedPNGWithTEXSExtractsAnimationTrack() throws {
        let buffer = makeEncodedPNGAtlasWithTEXS()
        let payload = try WPETexDecoder().extractTexturePayload(data: buffer).get()
        let track = try #require(payload.animationTrack)

        #expect(payload.hasAnimationFrames == true)
        #expect(payload.info.format == .rgba8888)
        #expect(track.frames.count == 2)
        #expect(track.frames[0].subRect == CGRect(x: 0, y: 0, width: 2, height: 2))
        #expect(track.frames[1].subRect == CGRect(x: 2, y: 0, width: 2, height: 2))
        #expect(track.frames[0].mipmaps.first?.bytes == track.frames[1].mipmaps.first?.bytes)
    }

    // P3: TEXI imageWidth/imageHeight + unknown int0 must reach
    // WPETexInfo so future runtime / dump consumers can cross-reference
    // padded atlas dimensions against the texture-coordinate space.
    @Test("TEXI imageWidth/imageHeight/unkInt0 surface into WPETexInfo")
    func texiUnknownFieldsAreRetained() throws {
        let buffer = makeImageWithTEXIImageDimensions(
            textureWidth: 4,
            textureHeight: 4,
            imageWidth: 3,
            imageHeight: 2,
            unknownInt0: 7
        )

        let info = try WPETexDecoder().probe(data: buffer).get()

        #expect(info.width == 4)
        #expect(info.height == 4)
        #expect(info.imageWidth == 3)
        #expect(info.imageHeight == 2)
        #expect(info.unknownInt0 == 7)
    }

    // P3: TEXB v4's `v4Param1/v4Param2/v4Condition/v4Param3` block is
    // only read when the parser keeps `effectiveBitmapVersion == 4`,
    // which today requires `isVideoMP4 == 1`. The video-payload branch
    // doesn't expose `WPETexMipmap.v4Fields` through any public API
    // (extractTexturePayload returns `videoPayload` + empty mipmaps),
    // so we can't round-trip v4Fields through `.decode` / `extractTexturePayload`
    // alone. The data flow is exercised end-to-end by
    // `WPESceneDebugArtifacts.dumpRawTexMetadata` which reads them off
    // the parser's internal `WPETexBitmapBlock`; the read-not-skip
    // contract is enforced by `readNullTerminatedString` in the byte
    // reader (which would otherwise mis-align the next mip read).

    @Test("Streaming extraction preserves TEXS sub-rects and compressed image payloads")
    func streamingExtractionPreservesSubRectsAndCompressedPayloads() throws {
        let width = 4
        let height = 4
        let raw0 = Data(repeating: 0x11, count: width * height * 4)
        let raw1 = Data(repeating: 0x22, count: width * height * 4)
        let compressed0 = try lz4RawCompress(raw0)
        let compressed1 = try lz4RawCompress(raw1)
        let buffer = makeStreamingTestImage(
            width: width,
            height: height,
            compressedPayloads: [compressed0, compressed1],
            decompressedByteCount: width * height * 4
        )

        let payload = try WPETexDecoder().extractStreamingPayload(data: buffer).get()

        #expect(payload.compressedImages.count == 2)
        #expect(payload.compressedImages[0].payloads[0].compressedBytes == compressed0)
        #expect(payload.compressedImages[0].payloads[0].isCompressed == true)
        #expect(payload.compressedImages[0].payloads[0].decompressedByteCount == width * height * 4)
        #expect(payload.frames.count == 4)
        #expect(payload.frames[0].imageID == 0)
        #expect(payload.frames[0].subRect == CGRect(x: 0, y: 0, width: 4, height: 2))
        #expect(payload.frames[1].imageID == 0)
        #expect(payload.frames[1].subRect == CGRect(x: 0, y: 2, width: 4, height: 2))
        #expect(payload.frames[2].imageID == 1)
        #expect(payload.frameRate > 0)
        #expect(payload.loop == true)
    }

    // MARK: - Fixture helpers

    /// Synthesises a TEXV0005 / TEXI0001 / TEXB0003 buffer carrying a uniform-colour RGBA8888 mipmap.
    private func makeRGBA8888TestImage(width: Int, height: Int) -> Data {
        let pixel: [UInt8] = [0xff, 0x80, 0x33, 0xff]
        var raw = Data()
        raw.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { raw.append(contentsOf: pixel) }
        return makeImage(
            width: width,
            height: height,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: raw
        )
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

    private func makeRePKGPNGBackedImage() -> Data {
        let payload = onePixelPNG()
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0001")
        appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
        appendUInt32(&buffer, 2)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 0)

        appendMagic(&buffer, magic: "TEXB0003")
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 13)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 1)
        appendUInt32(&buffer, 0)
        appendUInt32(&buffer, 0)
        appendUInt32(&buffer, UInt32(payload.count))
        buffer.append(payload)
        return buffer
    }

    private func onePixelPNG() -> Data {
        Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
            0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
            0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99,
            0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
            0x4e, 0x44, 0xae, 0x42, 0x60, 0x82
        ])
    }

    private func mp4HeaderPayload() -> Data {
        Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x6d, 0x70, 0x34, 0x32,
            0x00, 0x00, 0x00, 0x00,
            0x6d, 0x70, 0x34, 0x32,
            0x69, 0x73, 0x6f, 0x6d
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

    private func appendFloat32(_ data: inout Data, _ value: Float) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private func makeStreamingTestImage(
        width: Int,
        height: Int,
        compressedPayloads: [Data],
        decompressedByteCount: Int
    ) -> Data {
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0001")
        appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
        appendUInt32(&buffer, 0)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendInt32(&buffer, 0)

        appendMagic(&buffer, magic: "TEXB0004")
        appendInt32(&buffer, Int32(compressedPayloads.count))
        appendInt32(&buffer, -1)
        appendInt32(&buffer, 0)
        for payload in compressedPayloads {
            appendInt32(&buffer, 1)
            appendInt32(&buffer, Int32(width))
            appendInt32(&buffer, Int32(height))
            appendUInt32(&buffer, 1)
            appendUInt32(&buffer, UInt32(decompressedByteCount))
            appendUInt32(&buffer, UInt32(payload.count))
            buffer.append(payload)
        }

        appendMagic(&buffer, magic: "TEXS0003")
        appendInt32(&buffer, 4)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        for (imageID, rect) in [
            (0, (Float(0), Float(0), Float(width), Float(height / 2))),
            (0, (Float(0), Float(height / 2), Float(width), Float(height / 2))),
            (1, (Float(0), Float(0), Float(width), Float(height / 2))),
            (1, (Float(0), Float(height / 2), Float(width), Float(height / 2)))
        ] {
            appendInt32(&buffer, Int32(imageID))
            appendFloat32(&buffer, 0.03)
            appendFloat32(&buffer, rect.0)
            appendFloat32(&buffer, rect.1)
            appendFloat32(&buffer, rect.2)
            appendFloat32(&buffer, 0)
            appendFloat32(&buffer, 0)
            appendFloat32(&buffer, rect.3)
        }
        return buffer
    }

    /// PNG atlas (2×2 RGBA bytes encoded as PNG) wrapped in a TEXV0005
    /// container with a TEXB0003 encoded-payload + TEXS0003 schedule of
    /// 2 frames at 25 FPS. Synthesises the corpus's "encoded animated"
    /// shape (3 samples in 431960).
    private func makeEncodedPNGAtlasWithTEXS() -> Data {
        let pngBytes = twoByTwoPNGAtlas()
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0001")
        appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
        appendUInt32(&buffer, 2)   // flags: animation present
        appendInt32(&buffer, 4)    // textureWidth
        appendInt32(&buffer, 4)    // textureHeight
        appendInt32(&buffer, 4)    // imageWidth
        appendInt32(&buffer, 4)    // imageHeight
        appendInt32(&buffer, 0)    // unkInt0

        appendMagic(&buffer, magic: "TEXB0003")
        appendInt32(&buffer, 1)    // imageCount
        appendInt32(&buffer, 13)   // sourceImageFormatCode (encoded marker)
        appendInt32(&buffer, 1)    // mipmapCount
        appendInt32(&buffer, 4)    // mipWidth
        appendInt32(&buffer, 4)    // mipHeight
        appendUInt32(&buffer, 0)   // compressed flag
        appendUInt32(&buffer, UInt32(pngBytes.count))
        appendUInt32(&buffer, UInt32(pngBytes.count))
        buffer.append(pngBytes)

        appendMagic(&buffer, magic: "TEXS0003")
        appendInt32(&buffer, 2)    // frame count
        appendInt32(&buffer, 4)    // gifWidth
        appendInt32(&buffer, 4)    // gifHeight
        for (imageID, rect) in [
            (0, (Float(0), Float(0), Float(2), Float(2))),
            (0, (Float(2), Float(0), Float(2), Float(2)))
        ] {
            appendInt32(&buffer, Int32(imageID))
            appendFloat32(&buffer, 0.04)
            appendFloat32(&buffer, rect.0)
            appendFloat32(&buffer, rect.1)
            appendFloat32(&buffer, rect.2)
            appendFloat32(&buffer, 0)
            appendFloat32(&buffer, 0)
            appendFloat32(&buffer, rect.3)
        }
        return buffer
    }

    /// Generates a 4×4 RGBA PNG (uniform color per quadrant) used by the
    /// encoded-animated fixture. The fixture's TEXS schedule slices this
    /// atlas into two 2×2 sub-rects so the test can assert that
    /// `bridgeEncodedAnimatedImagePayload` returns 2 animation frames
    /// pointing at the same atlas with distinct sub-rects.
    private func twoByTwoPNGAtlas() -> Data {
        var pixels = Data()
        pixels.reserveCapacity(4 * 4 * 4)
        for row in 0..<4 {
            for col in 0..<4 {
                let red: UInt8 = col < 2 ? 0xff : 0x00
                let green: UInt8 = row < 2 ? 0xff : 0x00
                pixels.append(contentsOf: [red, green, 0x00, 0xff])
            }
        }
        let provider = CGDataProvider(data: pixels as CFData)!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        let image = CGImage(
            width: 4, height: 4,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let mutable = NSMutableData()
        let destination = CGImageDestinationCreateWithData(mutable, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return mutable as Data
    }

    /// TEXI fixture asserting that imageWidth/imageHeight/unkInt0
    /// survive into `WPETexInfo`.
    private func makeImageWithTEXIImageDimensions(
        textureWidth: Int,
        textureHeight: Int,
        imageWidth: Int,
        imageHeight: Int,
        unknownInt0: Int32
    ) -> Data {
        let pixel: [UInt8] = [0xff, 0x80, 0x33, 0xff]
        var raw = Data()
        raw.reserveCapacity(textureWidth * textureHeight * 4)
        for _ in 0..<(textureWidth * textureHeight) { raw.append(contentsOf: pixel) }
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0001")
        appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
        appendUInt32(&buffer, 0)
        appendInt32(&buffer, Int32(textureWidth))
        appendInt32(&buffer, Int32(textureHeight))
        appendInt32(&buffer, Int32(imageWidth))
        appendInt32(&buffer, Int32(imageHeight))
        appendInt32(&buffer, unknownInt0)

        appendMagic(&buffer, magic: "TEXB0003")
        appendInt32(&buffer, 1)
        appendInt32(&buffer, -1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, Int32(textureWidth))
        appendInt32(&buffer, Int32(textureHeight))
        appendUInt32(&buffer, 0)
        appendUInt32(&buffer, UInt32(raw.count))
        appendUInt32(&buffer, UInt32(raw.count))
        buffer.append(raw)
        return buffer
    }

    private func lz4RawCompress(_ data: Data) throws -> Data {
        let dstCapacity = data.count + 64
        var dst = Data(count: dstCapacity)
        let written = dst.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                guard let dstPtr = out.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = input.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return compression_encode_buffer(
                    dstPtr, dstCapacity,
                    srcPtr, data.count,
                    nil,
                    COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written > 0 else {
            throw NSError(domain: "lz4", code: -1)
        }
        return dst.prefix(written)
    }
}
