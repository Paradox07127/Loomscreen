import CoreGraphics
import Compression
import Foundation
import ImageIO

/// Stateless `.tex` decoder. Parses `TEXVxxxx` containers emitted by the
/// Wallpaper Engine publish pipeline and returns either the largest mipmap
/// of the first frame as a `CGImage` or a precise `WPETexDecodeError` so
/// the UI can surface the exact reason a layer failed (unsupported format
/// vs. truncated bytes vs. unknown container version).
///
/// Format coverage in Phase 2.1:
///   - CPU: RGBA8888, R8, RG88
///   - ImageIO-backed TEXB payloads: PNG/JPEG/etc. (`FreeImage` formats)
///   - Reject precisely: DXT1/3/5, BC7, RGBA1010102, animation/sequence frames
struct WPETexDecoder: Sendable {
    init() {}

    /// Cheap header probe — used by `WallpaperEngineImportService` during
    /// capability tier classification. Reads only as far as the `TEXI`
    /// block so we don't pay the full mipmap walk per layer at import time.
    func probe(data: Data) -> Result<WPETexInfo, WPETexDecodeError> {
        do {
            return .success(try parseHeader(data: data))
        } catch let error as WPETexDecodeError {
            return .failure(error)
        } catch {
            return .failure(.decodeFailed(mipmap: 0, detail: error.localizedDescription))
        }
    }

    /// Hot path. Reads container → info → bitmap, picks the largest mip,
    /// dispatches to the appropriate pixel decoder, and returns a CGImage.
    func decode(data: Data) -> Result<CGImage, WPETexDecodeError> {
        do {
            let parsed = try parse(data: data)
            return .success(try makeCGImage(from: parsed))
        } catch let error as WPETexDecodeError {
            return .failure(error)
        } catch {
            return .failure(.decodeFailed(mipmap: 0, detail: error.localizedDescription))
        }
    }

    // MARK: - Parsing

    private struct ParsedTex {
        let info: WPETexInfo
        let bitmap: WPETexBitmapBlock
        let hasAnimationFrames: Bool
    }

    private func parseHeader(data: Data) throws -> WPETexInfo {
        var reader = WPETexByteReader(data: data)
        let containerMagic = try reader.readMagic()
        guard containerMagic.hasPrefix("TEXV") else {
            throw WPETexDecodeError.unsupportedContainer(magic: containerMagic)
        }
        let containerVersion = parseTrailingVersion(containerMagic)

        // The first sub-block must be TEXI; otherwise the file is malformed.
        let infoMagic = try reader.readMagic()
        guard infoMagic.hasPrefix("TEXI") else {
            throw WPETexDecodeError.unsupportedBlock(magic: infoMagic)
        }
        return try parseInfoBlock(
            versionedMagic: infoMagic,
            containerVersion: containerVersion,
            reader: &reader
        )
    }

    private func parse(data: Data) throws -> ParsedTex {
        var reader = WPETexByteReader(data: data)
        let containerMagic = try reader.readMagic()
        guard containerMagic.hasPrefix("TEXV") else {
            throw WPETexDecodeError.unsupportedContainer(magic: containerMagic)
        }
        let containerVersion = parseTrailingVersion(containerMagic)

        var info: WPETexInfo?
        var bitmap: WPETexBitmapBlock?
        var hasAnimation = false

        while !reader.isAtEnd {
            let blockMagic = try reader.readMagic()
            switch blockMagic.prefix(4) {
            case "TEXI":
                info = try parseInfoBlock(
                    versionedMagic: blockMagic,
                    containerVersion: containerVersion,
                    reader: &reader
                )
            case "TEXB":
                guard let parsedInfo = info else {
                    throw WPETexDecodeError.missingInfoBlock
                }
                bitmap = try parseBitmapBlock(
                    versionedMagic: blockMagic,
                    info: parsedInfo,
                    reader: &reader
                )
                // Any bytes after TEXB (e.g. TEXS) we treat as animation.
                if !reader.isAtEnd { hasAnimation = true }
                break
            case "TEXS":
                hasAnimation = true
                // Phase 2.1 returns the still first frame; we don't need
                // the sequence payload for the image-only render path.
                break
            default:
                throw WPETexDecodeError.unsupportedBlock(magic: blockMagic)
            }
            // Once we have both info + bitmap we can stop walking — the
            // remaining frames go through Phase 2.x animation work.
            if info != nil, bitmap != nil { break }
        }

        guard let parsedInfo = info else { throw WPETexDecodeError.missingInfoBlock }
        guard let parsedBitmap = bitmap else { throw WPETexDecodeError.missingBitmapBlock }
        return ParsedTex(info: parsedInfo, bitmap: parsedBitmap, hasAnimationFrames: hasAnimation)
    }

    // MARK: - TEXI

    private func parseInfoBlock(
        versionedMagic: String,
        containerVersion: Int,
        reader: inout WPETexByteReader
    ) throws -> WPETexInfo {
        let infoVersion = parseTrailingVersion(versionedMagic)

        // Layout cross-checked against RePKG and linux-wallpaperengine:
        //   format (uint32)
        //   flags (uint32)
        //   textureWidth  (uint32, padded to power of 2)
        //   textureHeight (uint32)
        //   imageWidth    (uint32, actual visible pixels)
        //   imageHeight   (uint32)
        //   unkInt0       (uint32)
        // The image-vs-texture distinction matters: WPE pads compressed
        // textures to power-of-two for GPU upload, but stores the visible
        // sub-rect as `imageWidth/imageHeight`. We use the texture
        // dimensions (full payload) so the bitmap mipmaps line up; the
        // visible rect can be cropped at render time later.
        let formatCode = Int(try reader.readInt32(blockName: "TEXI.format"))
        let flags = try reader.readUInt32(blockName: "TEXI.flags")
        let textureWidth = Int(try reader.readInt32(blockName: "TEXI.textureWidth"))
        let textureHeight = Int(try reader.readInt32(blockName: "TEXI.textureHeight"))
        let imageWidth = Int(try reader.readInt32(blockName: "TEXI.imageWidth"))
        let imageHeight = Int(try reader.readInt32(blockName: "TEXI.imageHeight"))
        _ = imageWidth; _ = imageHeight
        _ = try reader.readInt32(blockName: "TEXI.unkInt0")

        let format = WPETexFormat(rawValue: formatCode)
        let info = WPETexInfo(
            containerVersion: containerVersion,
            infoVersion: infoVersion,
            width: max(textureWidth, 1),
            height: max(textureHeight, 1),
            textureFormatCode: formatCode,
            format: format,
            mipmapCount: 0,
            flags: flags
        )
        guard info.dimensionsLooksValid else {
            throw WPETexDecodeError.invalidDimensions(width: textureWidth, height: textureHeight)
        }
        return info
    }

    // MARK: - TEXB

    private func parseBitmapBlock(
        versionedMagic: String,
        info: WPETexInfo,
        reader: inout WPETexByteReader
    ) throws -> WPETexBitmapBlock {
        let bitmapVersion = parseTrailingVersion(versionedMagic)
        let imageCount = Int(try reader.readInt32(blockName: "TEXB.imageCount"))
        guard imageCount > 0 && imageCount <= 4_096 else {
            throw WPETexDecodeError.mipmapOutOfBounds(index: imageCount)
        }

        var sourceImageFormatCode: Int?
        var isVideoPayload = false
        var effectiveBitmapVersion = bitmapVersion
        switch bitmapVersion {
        case 1, 2:
            break
        case 3:
            sourceImageFormatCode = Int(try reader.readInt32(blockName: "TEXB.imageFormat"))
        case 4:
            sourceImageFormatCode = Int(try reader.readInt32(blockName: "TEXB.imageFormat"))
            isVideoPayload = try reader.readInt32(blockName: "TEXB.isVideoMP4") == 1
            // RePKG and linux-wallpaperengine both treat non-MP4 TEXB0004
            // as TEXB0003 for the mipmap layout.
            if !isVideoPayload {
                effectiveBitmapVersion = 3
            }
        default:
            throw WPETexDecodeError.unsupportedBlock(magic: versionedMagic)
        }

        var mipmaps: [WPETexMipmap] = []
        for imageIndex in 0..<imageCount {
            let mipmapCount = Int(try reader.readInt32(blockName: "TEXB.mipCount"))
            guard mipmapCount > 0 && mipmapCount <= 32 else {
                throw WPETexDecodeError.mipmapOutOfBounds(index: mipmapCount)
            }
            if imageIndex == 0 {
                mipmaps.reserveCapacity(mipmapCount)
            }

            for mipmapIndex in 0..<mipmapCount {
                let mipmap = try parseMipmap(
                    version: effectiveBitmapVersion,
                    index: mipmapIndex,
                    reader: &reader
                )
                if imageIndex == 0 {
                    mipmaps.append(mipmap)
                }
            }
        }
        return WPETexBitmapBlock(
            version: bitmapVersion,
            sourceImageFormatCode: sourceImageFormatCode,
            isVideoPayload: isVideoPayload,
            mipmaps: mipmaps
        )
    }

    private func parseMipmap(
        version: Int,
        index: Int,
        reader: inout WPETexByteReader
    ) throws -> WPETexMipmap {
        if version == 4 {
            _ = try reader.readInt32(blockName: "TEXB.v4Param1")
            _ = try reader.readInt32(blockName: "TEXB.v4Param2")
            try reader.skipNullTerminatedString(blockName: "TEXB.v4Condition")
            _ = try reader.readInt32(blockName: "TEXB.v4Param3")
        }

        let mipWidth = Int(try reader.readInt32(blockName: "TEXB.mipWidth"))
        let mipHeight = Int(try reader.readInt32(blockName: "TEXB.mipHeight"))

        var compressedFlag: UInt32 = 0
        var decompressedByteCount: Int?
        if version >= 2 {
            compressedFlag = try reader.readUInt32(blockName: "TEXB.mipCompressed")
            decompressedByteCount = Int(try reader.readUInt32(blockName: "TEXB.mipDecompressedSize"))
        }

        let storedSize = Int(try reader.readUInt32(blockName: "TEXB.mipSize"))
        let payload = try reader.readBytes(count: storedSize, blockName: "TEXB.mipPayload")

        return WPETexMipmap(
            index: index,
            width: max(mipWidth, 1),
            height: max(mipHeight, 1),
            storedByteCount: storedSize,
            decompressedByteCount: decompressedByteCount,
            payload: payload,
            isCompressed: compressedFlag != 0
        )
    }

    // MARK: - Pixel dispatch

    private func makeCGImage(from parsed: ParsedTex) throws -> CGImage {
        guard let mip = parsed.bitmap.largestMipmap else {
            throw WPETexDecodeError.missingBitmapBlock
        }
        if parsed.bitmap.isVideoPayload || looksLikeMP4Payload(mip.payload) {
            throw WPETexDecodeError.unsupportedAnimation
        }
        guard let format = parsed.info.format else {
            throw WPETexDecodeError.unsupportedFormat(code: parsed.info.textureFormatCode)
        }

        if parsed.bitmap.usesEncodedImagePayload {
            let imageBytes = try inflateIfNeeded(
                payload: mip.payload,
                expectedByteCount: nil,
                decompressedByteCount: mip.decompressedByteCount,
                isCompressed: mip.isCompressed,
                mipmap: mip.index
            )
            return try makeEncodedCGImage(from: imageBytes, mipmap: mip.index)
        }

        let expected = format.expectedByteCount(width: mip.width, height: mip.height)
        let pixelBytes: Data = try inflateIfNeeded(
            payload: mip.payload,
            expectedByteCount: expected,
            decompressedByteCount: mip.decompressedByteCount,
            isCompressed: mip.isCompressed,
            mipmap: mip.index
        )

        let decoded: DecodedRGBAImage
        switch format {
        case .rgba8888:
            decoded = try WPETexPixelDecoder.decodeRGBA8888(
                pixelBytes,
                width: mip.width,
                height: mip.height,
                mipmap: mip.index
            )
        case .r8:
            decoded = try WPETexPixelDecoder.decodeR8(
                pixelBytes,
                width: mip.width,
                height: mip.height,
                mipmap: mip.index
            )
        case .rg88:
            decoded = try WPETexPixelDecoder.decodeRG88(
                pixelBytes,
                width: mip.width,
                height: mip.height,
                mipmap: mip.index
            )
        case .dxt1, .dxt3, .dxt5, .bc7:
            decoded = try WPETexMetalTranscoder.transcode(
                pixelBytes,
                format: format,
                width: mip.width,
                height: mip.height,
                mipmap: mip.index
            )
        case .rgba1010102:
            // Phase 2.1 explicitly defers RGBA1010102; surface as
            // unsupported so the UI shows a precise reason.
            throw WPETexDecodeError.unsupportedFormat(code: format.rawValue)
        }
        return try decoded.makeCGImage()
    }

    private func looksLikeMP4Payload(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data[4] == 0x66
            && data[5] == 0x74
            && data[6] == 0x79
            && data[7] == 0x70
    }

    private func makeEncodedCGImage(from data: Data, mipmap: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WPETexDecodeError.decodeFailed(mipmap: mipmap, detail: "ImageIO could not decode encoded mip payload")
        }
        return image
    }

    /// Reconciles `payload` against `expectedByteCount`. Three cases:
    /// 1. Exact match → return as-is.
    /// 2. Mip flagged `compressed` (V3+) OR payload is shorter than
    ///    expected → run LZ4 raw decompression.
    /// 3. Otherwise (uncompressed flag, padded payload longer than
    ///    expected) → take the leading prefix. WPE's V1/V2 bitmaps
    ///    occasionally carry trailing slack bytes for alignment; treating
    ///    that as a decode failure was the source of false negatives in
    ///    early Phase 2.1 testing.
    private func inflateIfNeeded(
        payload: Data,
        expectedByteCount: Int?,
        decompressedByteCount: Int?,
        isCompressed: Bool,
        mipmap: Int
    ) throws -> Data {
        if isCompressed {
            let outputCount = decompressedByteCount.flatMap { $0 > 0 ? $0 : nil } ?? expectedByteCount ?? 0
            guard outputCount > 0 else {
                throw WPETexDecodeError.decompressionFailed(mipmap: mipmap)
            }
            let inflated = try lz4Inflate(payload: payload, outputCount: outputCount, mipmap: mipmap)
            if let expectedByteCount, inflated.count > expectedByteCount {
                return inflated.prefix(expectedByteCount)
            }
            return inflated
        }

        guard let expectedByteCount else { return payload }
        if payload.count == expectedByteCount { return payload }
        if payload.count > expectedByteCount {
            return payload.prefix(expectedByteCount)
        }

        // Legacy tolerance for old fixtures and early WPE variants that omit
        // the explicit compression flag but still store an LZ4 block.
        return try lz4Inflate(payload: payload, outputCount: expectedByteCount, mipmap: mipmap)
    }

    private func lz4Inflate(payload: Data, outputCount: Int, mipmap: Int) throws -> Data {
        var output = Data(count: outputCount)
        let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            payload.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                guard let dst = out.bindMemory(to: UInt8.self).baseAddress,
                      let src = input.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return compression_decode_buffer(
                    dst, outputCount,
                    src, payload.count,
                    nil,
                    COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written == outputCount else {
            throw WPETexDecodeError.decompressionFailed(mipmap: mipmap)
        }
        return output
    }

    // MARK: - Helpers

    /// "TEXV0005" → 5. Defaults to 0 when the suffix isn't a number so we
    /// can flag genuinely unknown containers later.
    private func parseTrailingVersion(_ magic: String) -> Int {
        let digits = magic.suffix(4)
        return Int(digits) ?? 0
    }
}
