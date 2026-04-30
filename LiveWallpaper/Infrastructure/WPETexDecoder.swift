import CoreGraphics
import Compression
import Foundation

/// Stateless `.tex` decoder. Parses `TEXVxxxx` containers emitted by the
/// Wallpaper Engine publish pipeline and returns either the largest mipmap
/// of the first frame as a `CGImage` or a precise `WPETexDecodeError` so
/// the UI can surface the exact reason a layer failed (unsupported format
/// vs. truncated bytes vs. unknown container version).
///
/// Format coverage in Phase 2.1:
///   - CPU: RGBA8888, R8, RG88
///   - GPU (Metal transcode, see `WPETexMetalTranscoder`): DXT1/3/5, BC7
///   - Reject precisely: RGBA1010102, animation/sequence frames
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

        // Layout cross-checked against linux-wallpaperengine's `CTexture`
        // and confirmed against the user's `TEXV0005`/`TEXI0001` samples:
        //   format (uint32)
        //   flags (uint32)
        //   textureWidth  (uint32, padded to power of 2)
        //   textureHeight (uint32)
        //   imageWidth    (uint32, actual visible pixels)
        //   imageHeight   (uint32)
        //   [unkInt0 (uint32) — V3+ only]
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
        // V3 adds a trailing `unkInt0`. We tolerate both shapes by peeking
        // — TEXB starts with the 9-byte ASCII magic, so the very next
        // bytes deciding whether to consume a uint32 is "if reader sees
        // 'TEXB' next, skip; otherwise consume". TEXI0003 reliably has it.
        if infoVersion >= 3 {
            _ = try reader.readInt32(blockName: "TEXI.unkInt0")
        }

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
        let mipmapCount = Int(try reader.readInt32(blockName: "TEXB.mipCount"))
        guard mipmapCount > 0 && mipmapCount <= 32 else {
            throw WPETexDecodeError.mipmapOutOfBounds(index: mipmapCount)
        }

        var mipmaps: [WPETexMipmap] = []
        mipmaps.reserveCapacity(mipmapCount)
        for index in 0..<mipmapCount {
            let mipWidth = Int(try reader.readInt32(blockName: "TEXB.mipWidth"))
            let mipHeight = Int(try reader.readInt32(blockName: "TEXB.mipHeight"))
            // V3 prepends a `compressed` flag UInt32; V2 / V1 omit it but
            // store the byte count next either way.
            var compressedFlag: UInt32 = 0
            if bitmapVersion >= 3 {
                compressedFlag = try reader.readUInt32(blockName: "TEXB.mipCompressed")
            }
            let storedSize = Int(try reader.readUInt32(blockName: "TEXB.mipSize"))
            let payload = try reader.readBytes(count: storedSize, blockName: "TEXB.mipPayload")

            mipmaps.append(WPETexMipmap(
                index: index,
                width: max(mipWidth, 1),
                height: max(mipHeight, 1),
                storedByteCount: storedSize,
                payload: payload,
                isCompressed: compressedFlag != 0
            ))
        }
        return WPETexBitmapBlock(version: bitmapVersion, mipmaps: mipmaps)
    }

    // MARK: - Pixel dispatch

    private func makeCGImage(from parsed: ParsedTex) throws -> CGImage {
        guard let mip = parsed.bitmap.largestMipmap else {
            throw WPETexDecodeError.missingBitmapBlock
        }
        guard let format = parsed.info.format else {
            throw WPETexDecodeError.unsupportedFormat(code: parsed.info.textureFormatCode)
        }

        let expected = format.expectedByteCount(width: mip.width, height: mip.height)
        let pixelBytes: Data = try inflateIfNeeded(
            payload: mip.payload,
            expectedByteCount: expected,
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
        expectedByteCount: Int,
        isCompressed: Bool,
        mipmap: Int
    ) throws -> Data {
        if payload.count == expectedByteCount { return payload }
        guard expectedByteCount > 0 else {
            throw WPETexDecodeError.decompressionFailed(mipmap: mipmap)
        }
        if !isCompressed && payload.count > expectedByteCount {
            return payload.prefix(expectedByteCount)
        }

        var output = Data(count: expectedByteCount)
        let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            payload.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                guard let dst = out.bindMemory(to: UInt8.self).baseAddress,
                      let src = input.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return compression_decode_buffer(
                    dst, expectedByteCount,
                    src, payload.count,
                    nil,
                    COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written == expectedByteCount else {
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
