import Compression
import Foundation
import Testing
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
        // No follow-up blocks. End of stream → missingInfoBlock.
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

    @Test("Unknown format code surfaces unsupportedFormat with the offending code")
    func unsupportedFormatCode() {
        // Format 99 doesn't map to any WPETexFormat — the decoder must
        // reject with the precise integer rather than a generic decode
        // error so the UI can show "Format 99 not yet supported".
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
        // Build an RGBA8888 mip and LZ4-compress its payload; the decoder
        // should detect the size mismatch and fall back to LZ4 inflate.
        let width = 4
        let height = 4
        let raw = Data((0..<(width * height * 4)).map { UInt8(($0 * 7) & 0xff) })
        let compressed = try lz4RawCompress(raw)
        // Don't bother synthesising a real lz4-compressed buffer if the
        // platform refuses to compress; just guard the test with a check.
        try #require(compressed.count != raw.count,
                     "LZ4 must yield a different byte count to exercise the inflate fallback")

        let buffer = makeImage(
            width: width,
            height: height,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: compressed
        )

        let result = WPETexDecoder().decode(data: buffer)
        guard case .success(let image) = result else {
            Issue.record("Expected decode success after LZ4 inflate, got \(result)")
            return
        }
        #expect(image.width == width)
        #expect(image.height == height)
    }

    // MARK: - Fixture helpers

    /// Synthesises a TEXV0005 / TEXI0001 / TEXB0003 buffer carrying a
    /// uniform-colour RGBA8888 mipmap. Test-only — production code never
    /// fabricates `.tex` files.
    private func makeRGBA8888TestImage(width: Int, height: Int) -> Data {
        // Solid orange so the decoded image is recognisable in debug.
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
        payload: Data
    ) -> Data {
        // Mirrors the field order observed in the user's `TEXV0005` /
        // `TEXI0001` samples (format → flags → textureW → textureH →
        // imageW → imageH). We emit the V3 info block (extra unkInt0) so
        // the decoder exercises the optional read.
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0003")
        appendInt32(&buffer, Int32(formatCode))
        appendUInt32(&buffer, 0)              // flags
        appendInt32(&buffer, Int32(width))    // textureWidth
        appendInt32(&buffer, Int32(height))   // textureHeight
        appendInt32(&buffer, Int32(width))    // imageWidth
        appendInt32(&buffer, Int32(height))   // imageHeight
        appendInt32(&buffer, 0)               // unkInt0 (V3)

        appendMagic(&buffer, magic: "TEXB0003")
        appendInt32(&buffer, 1)               // mipmapCount
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendUInt32(&buffer, 0)              // compressed flag (false)
        appendUInt32(&buffer, UInt32(payload.count))
        buffer.append(payload)
        return buffer
    }

    private func appendMagic(_ data: inout Data, magic: String) {
        data.append(contentsOf: magic.utf8)
        data.append(0x00) // NUL terminator
    }

    private func appendInt32(_ data: inout Data, _ value: Int32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    /// Compresses `data` using LZ4 raw. Mirrors what the decoder uses on
    /// the inflate side. Throws when the platform refuses (e.g. data is
    /// already smaller than the worst-case LZ4 frame size).
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
