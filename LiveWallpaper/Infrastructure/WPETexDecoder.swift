#if !LITE_BUILD
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

    /// Cheap header probe — used by `WallpaperEngineImportService` during capability tier classification.
    func probe(data: Data) -> Result<WPETexInfo, WPETexDecodeError> {
        do {
            return .success(try parseHeader(data: data))
        } catch let error as WPETexDecodeError {
            return .failure(error)
        } catch {
            return .failure(.decodeFailed(mipmap: 0, detail: error.localizedDescription))
        }
    }

    /// Hot path.
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

    /// Metal path.
    func extractTexturePayload(data: Data) -> Result<WPETexTexturePayload, WPETexDecodeError> {
        do {
            let parsed = try parse(data: data)

            if let videoPayload = makeVideoPayload(from: parsed) {
                return .success(WPETexTexturePayload(
                    info: parsed.info,
                    mipmaps: [],
                    hasAnimationFrames: false,
                    videoPayload: videoPayload
                ))
            }

            if parsed.bitmap.usesEncodedImagePayload {
                let bridgedPayload = try bridgeEncodedImagePayload(parsed)
                return .success(bridgedPayload)
            }

            let firstFrameMipmaps = try normalizedTextureMipmaps(
                parsed.bitmap.mipmaps,
                info: parsed.info
            )
            let animationTrack = try makeAnimationTrack(from: parsed)

            return .success(WPETexTexturePayload(
                info: parsed.info,
                mipmaps: firstFrameMipmaps,
                hasAnimationFrames: parsed.hasAnimationFrames,
                animationTrack: animationTrack
            ))
        } catch let error as WPETexDecodeError {
            return .failure(error)
        } catch {
            return .failure(.decodeFailed(mipmap: 0, detail: error.localizedDescription))
        }
    }

    private func normalizedTextureMipmaps(
        _ mipmaps: [WPETexMipmap],
        info: WPETexInfo
    ) throws -> [WPETexTextureMipmap] {
        try mipmaps.map { mipmap in
            WPETexTextureMipmap(
                index: mipmap.index,
                width: mipmap.width,
                height: mipmap.height,
                bytes: try normalizedBytes(
                    for: mipmap,
                    format: info.format,
                    textureFormatCode: info.textureFormatCode
                )
            )
        }
    }

    private func makeAnimationTrack(from parsed: ParsedTex) throws -> WPETexAnimationTrack? {
        guard parsed.bitmap.frames.count > 1 else { return nil }

        let frameInfos = parsed.frameInfo?.frames
        let defaultDuration = 1.0 / WPETexAnimationTrack.defaultFrameRate

        let frames = try parsed.bitmap.frames.enumerated().map { index, _ in
            let frameInfo = frameInfos?[safe: index]
            let imageID = frameInfo?.imageID ?? index
            let frameTime = frameInfo?.frameTime ?? 0
            let duration = frameTime > 0 ? frameTime : defaultDuration
            let sourceIndex = parsed.bitmap.frames.indices.contains(imageID) ? imageID : index
            return WPETexAnimationFrame(
                imageID: sourceIndex,
                duration: duration,
                mipmaps: try normalizedTextureMipmaps(parsed.bitmap.frames[sourceIndex], info: parsed.info)
            )
        }

        let validDurations = frames.map(\.duration).filter { $0 > 0 }
        let averageDuration = validDurations.isEmpty
            ? defaultDuration
            : validDurations.reduce(0, +) / Double(validDurations.count)
        let frameRate = averageDuration > 0
            ? 1.0 / averageDuration
            : WPETexAnimationTrack.defaultFrameRate

        return WPETexAnimationTrack(
            frames: frames,
            frameRate: frameRate,
            loop: true
        )
    }

    private func makeVideoPayload(from parsed: ParsedTex) -> WPETexVideoPayload? {
        guard let mip = parsed.bitmap.largestMipmap else { return nil }
        guard parsed.bitmap.isVideoPayload || looksLikeMP4Payload(mip.payload) else {
            return nil
        }
        return WPETexVideoPayload(bytes: mip.payload)
    }

    // MARK: - Parsing

    private struct ParsedTex {
        let info: WPETexInfo
        let bitmap: WPETexBitmapBlock
        let frameInfo: WPETexFrameInfoBlock?
        let hasAnimationFrames: Bool
    }

    /// Parsed `TEXS` block. Phase 2E only consumes `frameTime` from the
    /// frame metadata; the UV crop/rotate fields are recorded for a later
    /// phase (atlas-driven WPE animation).
    private struct WPETexFrameInfoBlock {
        let version: Int
        let gifWidth: Int?
        let gifHeight: Int?
        let frames: [WPETexFrameInfo]
    }

    private struct WPETexFrameInfo {
        let imageID: Int
        let frameTime: TimeInterval
        let x: Float
        let y: Float
        let width: Float
        let widthY: Float
        let heightX: Float
        let height: Float
    }

    private func parseHeader(data: Data) throws -> WPETexInfo {
        var reader = WPETexByteReader(data: data)
        let containerMagic = try reader.readMagic()
        guard containerMagic.hasPrefix("TEXV") else {
            throw WPETexDecodeError.unsupportedContainer(magic: containerMagic)
        }
        let containerVersion = parseTrailingVersion(containerMagic)

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
        var frameInfo: WPETexFrameInfoBlock?

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

            case "TEXS":
                frameInfo = try parseFrameInfoBlock(
                    versionedMagic: blockMagic,
                    reader: &reader
                )

            default:
                throw WPETexDecodeError.unsupportedBlock(magic: blockMagic)
            }
        }

        guard let parsedInfo = info else { throw WPETexDecodeError.missingInfoBlock }
        guard let parsedBitmap = bitmap else { throw WPETexDecodeError.missingBitmapBlock }

        let hasAnimation = parsedBitmap.frames.count > 1 || frameInfo != nil
        return ParsedTex(
            info: parsedInfo,
            bitmap: parsedBitmap,
            frameInfo: frameInfo,
            hasAnimationFrames: hasAnimation
        )
    }

    /// Parses the optional `TEXS` block.
    private func parseFrameInfoBlock(
        versionedMagic: String,
        reader: inout WPETexByteReader
    ) throws -> WPETexFrameInfoBlock {
        let version = parseTrailingVersion(versionedMagic)
        let frameCount = Int(try reader.readInt32(blockName: "TEXS.frameCount"))
        guard frameCount > 0 && frameCount <= 4_096 else {
            throw WPETexDecodeError.mipmapOutOfBounds(index: frameCount)
        }

        let gifWidth: Int?
        let gifHeight: Int?
        if version == 3 {
            gifWidth = Int(try reader.readInt32(blockName: "TEXS.gifWidth"))
            gifHeight = Int(try reader.readInt32(blockName: "TEXS.gifHeight"))
        } else {
            gifWidth = nil
            gifHeight = nil
        }

        var frames: [WPETexFrameInfo] = []
        frames.reserveCapacity(frameCount)

        for _ in 0..<frameCount {
            let imageID = Int(try reader.readInt32(blockName: "TEXS.imageID"))
            let frameTime = TimeInterval(try reader.readFloat32(blockName: "TEXS.frameTime"))

            if version == 1 {
                frames.append(WPETexFrameInfo(
                    imageID: imageID,
                    frameTime: frameTime,
                    x: Float(try reader.readInt32(blockName: "TEXS.x")),
                    y: Float(try reader.readInt32(blockName: "TEXS.y")),
                    width: Float(try reader.readInt32(blockName: "TEXS.width")),
                    widthY: Float(try reader.readInt32(blockName: "TEXS.widthY")),
                    heightX: Float(try reader.readInt32(blockName: "TEXS.heightX")),
                    height: Float(try reader.readInt32(blockName: "TEXS.height"))
                ))
            } else if version == 2 || version == 3 {
                frames.append(WPETexFrameInfo(
                    imageID: imageID,
                    frameTime: frameTime,
                    x: try reader.readFloat32(blockName: "TEXS.x"),
                    y: try reader.readFloat32(blockName: "TEXS.y"),
                    width: try reader.readFloat32(blockName: "TEXS.width"),
                    widthY: try reader.readFloat32(blockName: "TEXS.widthY"),
                    heightX: try reader.readFloat32(blockName: "TEXS.heightX"),
                    height: try reader.readFloat32(blockName: "TEXS.height")
                ))
            } else {
                throw WPETexDecodeError.unsupportedBlock(magic: versionedMagic)
            }
        }

        return WPETexFrameInfoBlock(
            version: version,
            gifWidth: gifWidth,
            gifHeight: gifHeight,
            frames: frames
        )
    }

    // MARK: - TEXI

    private func parseInfoBlock(
        versionedMagic: String,
        containerVersion: Int,
        reader: inout WPETexByteReader
    ) throws -> WPETexInfo {
        let infoVersion = parseTrailingVersion(versionedMagic)

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
            if !isVideoPayload {
                effectiveBitmapVersion = 3
            }
        default:
            throw WPETexDecodeError.unsupportedBlock(magic: versionedMagic)
        }

        var frames: [[WPETexMipmap]] = []
        frames.reserveCapacity(imageCount)
        for _ in 0..<imageCount {
            let mipmapCount = Int(try reader.readInt32(blockName: "TEXB.mipCount"))
            guard mipmapCount > 0 && mipmapCount <= 32 else {
                throw WPETexDecodeError.mipmapOutOfBounds(index: mipmapCount)
            }

            var frameMipmaps: [WPETexMipmap] = []
            frameMipmaps.reserveCapacity(mipmapCount)
            for mipmapIndex in 0..<mipmapCount {
                frameMipmaps.append(try parseMipmap(
                    version: effectiveBitmapVersion,
                    index: mipmapIndex,
                    reader: &reader
                ))
            }
            frames.append(frameMipmaps)
        }
        return WPETexBitmapBlock(
            version: bitmapVersion,
            sourceImageFormatCode: sourceImageFormatCode,
            isVideoPayload: isVideoPayload,
            frames: frames
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

    /// Converts a TEXB-encoded image payload (PNG/JPEG bytes wrapped inside a WPE `.tex` file) into a synthetic `WPETexTexturePayload` shaped like raw RGBA8888 so the existing Metal upload path can consume it without branching on encoded-vs-raw at every call site.
    private func bridgeEncodedImagePayload(_ parsed: ParsedTex) throws -> WPETexTexturePayload {
        guard !parsed.hasAnimationFrames else {
            throw WPETexDecodeError.unsupportedAnimation
        }
        guard let mip = parsed.bitmap.largestMipmap else {
            throw WPETexDecodeError.missingBitmapBlock
        }
        let payloadBytes = try inflateIfNeeded(
            payload: mip.payload,
            expectedByteCount: nil,
            decompressedByteCount: mip.decompressedByteCount,
            isCompressed: mip.isCompressed,
            mipmap: mip.index
        )
        let image = try makeEncodedCGImage(from: payloadBytes, mipmap: mip.index)
        let rgba = try rasterizeRGBA8(from: image, mipmap: mip.index)

        let bridgedInfo = WPETexInfo(
            containerVersion: parsed.info.containerVersion,
            infoVersion: parsed.info.infoVersion,
            width: rgba.width,
            height: rgba.height,
            textureFormatCode: WPETexFormat.rgba8888.rawValue,
            format: .rgba8888,
            mipmapCount: 1,
            flags: parsed.info.flags
        )
        let bridgedMipmap = WPETexTextureMipmap(
            index: 0,
            width: rgba.width,
            height: rgba.height,
            bytes: rgba.pixels
        )
        return WPETexTexturePayload(
            info: bridgedInfo,
            mipmaps: [bridgedMipmap],
            hasAnimationFrames: false
        )
    }

    /// Renders a `CGImage` into straight-alpha, sRGB-encoded RGBA8 bytes suitable for upload as `MTLPixelFormat.rgba8Unorm_srgb`.
    private func rasterizeRGBA8(from image: CGImage, mipmap: Int) throws -> DecodedRGBAImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= Int.max / 4,
              height <= Int.max / max(width * 4, 1) else {
            throw WPETexDecodeError.invalidDimensions(width: width, height: height)
        }
        let bytesPerRow = width * 4
        var buffer = Data(count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let drew = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw WPETexDecodeError.decodeFailed(mipmap: mipmap, detail: "CGContext allocation or draw failed for encoded payload")
        }
        unpremultiplyAlphaLast(&buffer)
        return DecodedRGBAImage(width: width, height: height, pixels: buffer)
    }

    /// Reverses `CGImageAlphaInfo.premultipliedLast` in place so semi- transparent pixels are emitted as straight-alpha RGBA8.
    private func unpremultiplyAlphaLast(_ buffer: inout Data) {
        buffer.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset + 3 < bytes.count {
                let alpha = Int(base[offset + 3])
                if alpha == 0 {
                    base[offset]     = 0
                    base[offset + 1] = 0
                    base[offset + 2] = 0
                } else if alpha < 255 {
                    let halfAlpha = alpha / 2
                    base[offset]     = UInt8(min(255, (Int(base[offset])     * 255 + halfAlpha) / alpha))
                    base[offset + 1] = UInt8(min(255, (Int(base[offset + 1]) * 255 + halfAlpha) / alpha))
                    base[offset + 2] = UInt8(min(255, (Int(base[offset + 2]) * 255 + halfAlpha) / alpha))
                }
                offset += 4
            }
        }
    }

    private func normalizedBytes(
        for mipmap: WPETexMipmap,
        format: WPETexFormat?,
        textureFormatCode: Int
    ) throws -> Data {
        guard let format else {
            throw WPETexDecodeError.unsupportedFormat(code: textureFormatCode)
        }
        return try inflateIfNeeded(
            payload: mipmap.payload,
            expectedByteCount: format.expectedByteCount(width: mipmap.width, height: mipmap.height),
            decompressedByteCount: mipmap.decompressedByteCount,
            isCompressed: mipmap.isCompressed,
            mipmap: mipmap.index
        )
    }

    /// Reconciles `payload` against `expectedByteCount`.
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

    /// "TEXV0005" → 5.
    private func parseTrailingVersion(_ magic: String) -> Int {
        let digits = magic.suffix(4)
        return Int(digits) ?? 0
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
