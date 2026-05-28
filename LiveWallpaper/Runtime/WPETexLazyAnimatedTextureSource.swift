#if !LITE_BUILD
import Compression
import Foundation
import Metal

/// On-demand multi-frame `.tex` playback. Keeps each source image's
/// LZ4-compressed bytes resident in CPU RAM (≈ source `.tex` file size),
/// decompresses the image referenced by the current TEXS frame, crops its
/// sub-rect, and uploads into a single rotating `MTLTexture`. Block-
/// compressed (BC1/BC2/BC3/BC7) payloads stay compressed all the way to
/// the GPU — Apple Silicon samples them natively — so a workshop scene
/// like 3725117707 (60 BC3 source images, 4216×7248 each) lands at
/// ~785 MB CPU + ~10 MB GPU instead of the ~7.3 GB GPU the eager
/// transcoded path would demand.
@MainActor
final class WPETexLazyAnimatedTextureSource: WPEDynamicTextureSource {
    enum Failure: Error, Equatable, Sendable {
        case missingFrames
        case unsupportedFormat(Int)
        case missingCompressedImage(Int)
        case missingMipmap(Int)
        case decompressionFailed(Int)
        case textureAllocationFailed
        case textureDimensionsExceedDeviceLimit(width: Int, height: Int, limit: Int)
        case truncatedImageBytes
        case subRectNotBlockAligned(CGRect, blockSize: Int)
    }

    private let frames: [WPETexStreamingFrame]
    private let compressedImages: [WPETexCompressedImage]
    private let frameRate: Double
    private let loop: Bool
    private let device: MTLDevice
    private let label: String
    private let mapping: WPEMetalTextureFormatMapping
    private let maximumTextureDimension2D: Int
    private let frameStartTimes: [TimeInterval]
    private let totalDuration: TimeInterval

    private var workingTexture: MTLTexture?
    private var workingTextureWidth = 0
    private var workingTextureHeight = 0
    private var lastUploadedFrameIndex = -1
    private var decodedImageCache: [Int: Data] = [:]
    private var decodedImageOrder: [Int] = []
    private var lastErrorDescription: String?

    /// Keep this many recently-decompressed images warm so the typical
    /// "3 sub-rects per source image" pattern (TEXS frame 0/1/2 all
    /// reference imageID=0) avoids re-running LZ4 every animation frame.
    private static let decompressedImageCacheCapacity = 2

    init(
        payload: WPETexStreamingPayload,
        device: MTLDevice,
        label: String,
        capabilities: WPEMetalTextureCapabilities? = nil,
        maximumTextureDimension2D: Int? = nil
    ) throws {
        guard !payload.frames.isEmpty else { throw Failure.missingFrames }
        guard let format = payload.info.format else {
            throw Failure.unsupportedFormat(payload.info.textureFormatCode)
        }
        let caps = capabilities ?? WPEMetalTextureCapabilities(device: device)
        do {
            self.mapping = try WPEMetalTextureFormatMapper.mapping(for: format, capabilities: caps)
        } catch {
            throw Failure.unsupportedFormat(payload.info.textureFormatCode)
        }
        self.frames = payload.frames
        self.compressedImages = payload.compressedImages
        self.frameRate = payload.frameRate > 0 ? payload.frameRate : WPETexAnimationTrack.defaultFrameRate
        self.loop = payload.loop
        self.device = device
        self.label = label
        self.maximumTextureDimension2D = maximumTextureDimension2D
            ?? WPEMetalTextureLimits.maximum2DTextureDimension(for: device)

        var cursor: TimeInterval = 0
        var starts: [TimeInterval] = []
        starts.reserveCapacity(payload.frames.count)
        for frame in payload.frames {
            starts.append(cursor)
            cursor += frame.duration > 0 ? frame.duration : 1.0 / self.frameRate
        }
        self.frameStartTimes = starts
        self.totalDuration = cursor > 0 ? cursor : Double(payload.frames.count) / self.frameRate
    }

    func texture(at time: TimeInterval) -> MTLTexture? {
        let index = frameIndex(at: time)
        if index == lastUploadedFrameIndex {
            return workingTexture
        }

        do {
            let frame = frames[index]
            let image = try decodedImage(for: frame.imageID)
            let cropped = try crop(image: image, frame: frame)
            let texture = try textureForUpload(width: cropped.width, height: cropped.height)
            cropped.bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, cropped.width, cropped.height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: cropped.bytesPerRow
                )
            }
            lastUploadedFrameIndex = index
            return texture
        } catch {
            let message = "\(error)"
            if lastErrorDescription != message {
                lastErrorDescription = message
                Logger.warning("WPE lazy .tex upload failed for \(label): \(message)", category: .screenManager)
            }
            return workingTexture
        }
    }

    func frameIndex(at time: TimeInterval) -> Int {
        guard !frames.isEmpty else { return 0 }
        let bounded: TimeInterval
        if loop {
            let positive = max(time, 0)
            bounded = totalDuration > 0 ? positive.truncatingRemainder(dividingBy: totalDuration) : 0
        } else {
            bounded = min(max(time, 0), max(totalDuration - .ulpOfOne, 0))
        }

        var lo = 0
        var hi = frameStartTimes.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let start = frameStartTimes[mid]
            let next = mid + 1 < frameStartTimes.count ? frameStartTimes[mid + 1] : totalDuration
            if bounded < start {
                hi = mid - 1
            } else if bounded >= next {
                lo = mid + 1
            } else {
                return mid
            }
        }
        return max(min(lo, frames.count - 1), 0)
    }

    func debugFrameDescription(at time: TimeInterval) -> String {
        let index = frameIndex(at: time)
        let frame = frames[index]
        let rect = frame.subRect
        return "lazy:\(index)/image\(frame.imageID)[\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width))x\(Int(rect.height))]"
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        _ = profile
    }

    func invalidate() {
        workingTexture = nil
        workingTextureWidth = 0
        workingTextureHeight = 0
        lastUploadedFrameIndex = -1
        decodedImageCache.removeAll(keepingCapacity: false)
        decodedImageOrder.removeAll(keepingCapacity: false)
    }

    // MARK: - Decode + crop

    private func decodedImage(for imageID: Int) throws -> Data {
        if let cached = decodedImageCache[imageID] {
            touchDecodedImage(imageID)
            return cached
        }
        guard compressedImages.indices.contains(imageID) else {
            throw Failure.missingCompressedImage(imageID)
        }
        guard let mipmap = compressedImages[imageID].payloads.first else {
            throw Failure.missingMipmap(imageID)
        }

        let decoded: Data
        if mipmap.isCompressed {
            decoded = try inflate(mipmap)
        } else if mipmap.compressedBytes.count >= mipmap.decompressedByteCount {
            decoded = mipmap.compressedBytes.prefix(mipmap.decompressedByteCount)
        } else {
            throw Failure.truncatedImageBytes
        }

        decodedImageCache[imageID] = decoded
        decodedImageOrder.append(imageID)
        evictIfNeeded()
        return decoded
    }

    private func touchDecodedImage(_ imageID: Int) {
        decodedImageOrder.removeAll { $0 == imageID }
        decodedImageOrder.append(imageID)
    }

    private func evictIfNeeded() {
        while decodedImageOrder.count > Self.decompressedImageCacheCapacity,
              let victim = decodedImageOrder.first {
            decodedImageOrder.removeFirst()
            decodedImageCache.removeValue(forKey: victim)
        }
    }

    private func inflate(_ mipmap: WPETexCompressedMipmap) throws -> Data {
        let outputCount = mipmap.decompressedByteCount
        guard outputCount > 0 else { throw Failure.decompressionFailed(mipmap.index) }
        var output = Data(count: outputCount)
        let written = output.withUnsafeMutableBytes { outRaw -> Int in
            mipmap.compressedBytes.withUnsafeBytes { srcRaw -> Int in
                guard let dst = outRaw.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(
                    dst, outputCount,
                    src, mipmap.compressedBytes.count,
                    nil,
                    COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written == outputCount else { throw Failure.decompressionFailed(mipmap.index) }
        return output
    }

    private struct Cropped {
        let bytes: Data
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    /// Crops a sub-rect from the decompressed image. For uncompressed
    /// formats the work is a row-by-row byte copy. For BC-block formats
    /// the work is the same shape but in 4×4-pixel block units — Apple
    /// Silicon samples BC1/BC2/BC3/BC7 natively so we never have to
    /// transcode to RGBA. TEXS rects in published scenes are typically
    /// block-aligned (workshop 3725117707 uses 0/2416/4832 y-offsets,
    /// all multiples of 4); non-aligned rects throw rather than silently
    /// emit a torn output.
    private func crop(image: Data, frame: WPETexStreamingFrame) throws -> Cropped {
        guard compressedImages.indices.contains(frame.imageID),
              let mipmap = compressedImages[frame.imageID].payloads.first else {
            throw Failure.missingCompressedImage(frame.imageID)
        }
        let rect = pixelRect(frame.subRect, width: mipmap.width, height: mipmap.height)
        try validateTextureDimensions(width: rect.width, height: rect.height)

        if let bytesPerPixel = mapping.bytesPerPixel {
            let sourceBytesPerRow = mipmap.width * bytesPerPixel
            let outputBytesPerRow = rect.width * bytesPerPixel
            guard image.count >= sourceBytesPerRow * mipmap.height else {
                throw Failure.truncatedImageBytes
            }
            var output = Data(count: outputBytesPerRow * rect.height)
            image.withUnsafeBytes { srcRaw in
                output.withUnsafeMutableBytes { dstRaw in
                    guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                          let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                    for row in 0..<rect.height {
                        let srcOffset = (rect.y + row) * sourceBytesPerRow + rect.x * bytesPerPixel
                        let dstOffset = row * outputBytesPerRow
                        dst.advanced(by: dstOffset).update(from: src.advanced(by: srcOffset), count: outputBytesPerRow)
                    }
                }
            }
            return Cropped(bytes: output, width: rect.width, height: rect.height, bytesPerRow: outputBytesPerRow)
        }

        guard let bytesPerBlock = mapping.bytesPerBlock else {
            throw Failure.unsupportedFormat(0)
        }
        let blockSize = 4
        guard rect.x % blockSize == 0,
              rect.y % blockSize == 0,
              rect.width % blockSize == 0,
              rect.height % blockSize == 0 else {
            throw Failure.subRectNotBlockAligned(
                CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                blockSize: blockSize
            )
        }
        let sourceBlocksX = max((mipmap.width + blockSize - 1) / blockSize, 1)
        let sourceBlocksY = max((mipmap.height + blockSize - 1) / blockSize, 1)
        let cropBlocksX = rect.width / blockSize
        let cropBlocksY = rect.height / blockSize
        let originBlockX = rect.x / blockSize
        let originBlockY = rect.y / blockSize
        let sourceBytesPerBlockRow = sourceBlocksX * bytesPerBlock
        let outputBytesPerBlockRow = cropBlocksX * bytesPerBlock
        guard image.count >= sourceBytesPerBlockRow * sourceBlocksY else {
            throw Failure.truncatedImageBytes
        }
        var output = Data(count: outputBytesPerBlockRow * cropBlocksY)
        image.withUnsafeBytes { srcRaw in
            output.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                      let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                for blockRow in 0..<cropBlocksY {
                    let srcOffset = (originBlockY + blockRow) * sourceBytesPerBlockRow + originBlockX * bytesPerBlock
                    let dstOffset = blockRow * outputBytesPerBlockRow
                    dst.advanced(by: dstOffset).update(from: src.advanced(by: srcOffset), count: outputBytesPerBlockRow)
                }
            }
        }
        return Cropped(bytes: output, width: rect.width, height: rect.height, bytesPerRow: outputBytesPerBlockRow)
    }

    private struct PixelRect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private func pixelRect(_ rect: CGRect, width: Int, height: Int) -> PixelRect {
        // TEXS frames usually carry integer pixel coords stored as Float,
        // but some published assets use e.g. 2415.9999 to denote 2416.
        // Snap-to-nearest before clamping so we don't drop a row/column
        // and introduce a 1px seam at the sub-frame boundary.
        let snappedX = rect.origin.x.rounded(.toNearestOrAwayFromZero)
        let snappedY = rect.origin.y.rounded(.toNearestOrAwayFromZero)
        let snappedW = rect.width.rounded(.toNearestOrAwayFromZero)
        let snappedH = rect.height.rounded(.toNearestOrAwayFromZero)

        let x = min(max(Int(snappedX), 0), max(width - 1, 0))
        let y = min(max(Int(snappedY), 0), max(height - 1, 0))
        let w = min(max(Int(snappedW), 1), max(width - x, 1))
        let h = min(max(Int(snappedH), 1), max(height - y, 1))
        return PixelRect(x: x, y: y, width: w, height: h)
    }

    private func textureForUpload(width: Int, height: Int) throws -> MTLTexture {
        try validateTextureDimensions(width: width, height: height)
        if let texture = workingTexture,
           workingTextureWidth == width,
           workingTextureHeight == height {
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mapping.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure.textureAllocationFailed
        }
        texture.label = "\(label) lazy frame"
        workingTexture = texture
        workingTextureWidth = width
        workingTextureHeight = height
        lastUploadedFrameIndex = -1
        return texture
    }

    private func validateTextureDimensions(width: Int, height: Int) throws {
        guard width <= maximumTextureDimension2D,
              height <= maximumTextureDimension2D else {
            throw Failure.textureDimensionsExceedDeviceLimit(
                width: width,
                height: height,
                limit: maximumTextureDimension2D
            )
        }
    }

}
#endif
