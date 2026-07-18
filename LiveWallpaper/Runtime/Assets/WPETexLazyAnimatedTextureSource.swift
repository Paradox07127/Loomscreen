#if !LITE_BUILD
import Compression
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import os

/// On-demand multi-frame `.tex` playback. Keeps each source image's
/// LZ4-compressed bytes resident in CPU RAM (≈ source `.tex` file size),
/// decompresses the image referenced by the current TEXS frame, crops its
/// sub-rect, and uploads into a single rotating `MTLTexture`. Block-
/// compressed (BC1/BC2/BC3/BC7) payloads stay compressed all the way to
/// the GPU — Apple Silicon samples them natively — so a workshop scene
/// like 3725117707 (60 BC3 source images, 4216×7248 each) lands at
/// ~785 MB CPU + ~10 MB GPU instead of the ~7.3 GB GPU the eager
/// transcoded path would demand.
// Not `@MainActor` (M2c1b-3c): created and ticked inside the renderer's actor
// isolation. The off-thread LZ4 prefetch used to hop its completion back to the
// main actor; now it writes each decode into a `Sendable` lock-box that the
// render actor harvests on its next tick — so no non-Sendable `self` crosses a
// thread boundary and the source needs no actor reference.
final class WPETexLazyAnimatedTextureSource: WPEDynamicTextureSource {
    /// Result channel for one off-thread prefetch decode. `.pending` until the
    /// prefetch queue writes `.done`; harvested (and removed) on the render actor.
    private enum PrefetchOutcome: Sendable {
        case pending
        case done(Data?)
    }

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
    private let alphaChannelPriorityRG88: Bool
    private let maximumTextureDimension2D: Int
    private let frameStartTimes: [TimeInterval]
    private let totalDuration: TimeInterval
    /// Off-main queue for LZ4 inflate of upcoming frames so the render thread finds
    /// them decoded — kills the synchronous decode that stutters at the loop seam.
    /// `.userInitiated` so the render thread doesn't outrun a `.utility`-starved
    /// prefetch under load.
    private let prefetchQueue = DispatchQueue(
        label: "com.livewallpaper.wpe.lazy-tex-prefetch",
        qos: .userInitiated
    )

    private var workingTexture: MTLTexture?
    private var workingTextureWidth = 0
    private var workingTextureHeight = 0
    private var lastUploadedFrameIndex = -1
    private var decodedImageCache: [Int: Data] = [:]
    private var decodedImageOrder: [Int] = []
    /// Source images being inflated on `prefetchQueue`, keyed by imageID. Each
    /// job carries its cancellable work item plus the `Sendable` box the work
    /// item writes its decode into (dedup + bounded backlog + drop on invalidate /
    /// when the image leaves the look-ahead window).
    private var prefetchJobs: [Int: (item: DispatchWorkItem, box: OSAllocatedUnfairLock<PrefetchOutcome>)] = [:]
    /// Images whose decode threw — never re-scheduled, so a corrupt frame can't
    /// spin up a background inflate every render tick.
    private var prefetchFailedImageIDs: Set<Int> = []
    /// The images the most recent schedule wants warm; a completion outside this
    /// set is stale (playback moved on) and is dropped so it can't LRU-evict the
    /// current/next image.
    private var prefetchWantedImageIDs: Set<Int> = []
    private var lastScheduledFrameIndex = -1
    private var lastErrorDescription: String?
    /// Completion pump: called (from the prefetch queue) each time an off-thread
    /// decode finishes, so the owner can hop back into the source's isolation and
    /// `harvestCompletedPrefetches()` immediately — preserving the pre-3c
    /// "prefetch lands when it completes" contract instead of waiting for the
    /// next `texture(at:)` tick. The renderer installs an actor-hop here; when
    /// unset (unit tests), the debug probes harvest on read.
    var onPrefetchComplete: (@Sendable () -> Void)?

#if DEBUG
    var debugPrefetchDecodeDelay: TimeInterval = 0
    private(set) var debugSynchronousDecodedImageIDs: [Int] = []
    // The probes harvest first so a test (no completion pump installed) observes a
    // finished decode as soon as it polls — the probe IS the caller's isolation.
    var debugDecodedImageCacheIDs: Set<Int> {
        harvestCompletedPrefetches()
        return Set(decodedImageCache.keys)
    }
    var debugPrefetchInFlightImageIDs: Set<Int> {
        harvestCompletedPrefetches()
        return Set(prefetchJobs.keys)
    }
    var debugPrefetchFailedImageIDs: Set<Int> {
        harvestCompletedPrefetches()
        return prefetchFailedImageIDs
    }
#endif

    /// How many DISTINCT upcoming source images to keep warm (wrap-aware). Scanned
    /// by image, not frame, so a multi-sub-rect atlas is prefetched with enough
    /// lead time while the current atlas is still being reused.
    private static let decodedImagePrefetchLookahead = 2
    /// Bounds the decoded-image cache to the current image + the prefetch window
    /// + one slack slot, so a just-prefetched image isn't evicted before use.
    /// An upper bound, not a target — the common "3 sub-rects per source image"
    /// pattern keeps far fewer distinct images resident.
    private static let decompressedImageCacheCapacity = 4

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
        self.alphaChannelPriorityRG88 = WPEMetalTextureLoader.rg88NeedsLuminanceAlphaSwizzle(
            isLuminanceAlpha: payload.info.isRG88LuminanceAlpha,
            label: label
        )
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
        defer { scheduleDecodedImagePrefetch(after: index) }
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
        // Cancel + drop in-flight jobs; a work item that still runs writes into its
        // now-orphaned box and is never harvested (the job was removed here).
        for job in prefetchJobs.values { job.item.cancel() }
        prefetchJobs.removeAll(keepingCapacity: false)
        prefetchFailedImageIDs.removeAll(keepingCapacity: false)
        prefetchWantedImageIDs.removeAll(keepingCapacity: false)
        lastScheduledFrameIndex = -1
    }

    // MARK: - Decode + crop

    private func decodedImage(for imageID: Int) throws -> Data {
        // A prefetch for this image may already have completed off-thread.
        harvestCompletedPrefetches()
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

        // The render thread reached this image before its prefetch finished:
        // cancel the in-flight job so it can't redundantly inflate or post a
        // late completion, then decode synchronously (the rare fallback).
        cancelPrefetch(for: imageID)
        let decoded: Data
        do {
            decoded = try Self.decodedBytes(from: mipmap)
        } catch {
            prefetchFailedImageIDs.insert(imageID)
            throw error
        }
#if DEBUG
        debugSynchronousDecodedImageIDs.append(imageID)
#endif
        storeDecodedImage(decoded, for: imageID)
        return decoded
    }

    /// Keeps the next `decodedImagePrefetchLookahead` DISTINCT source images warm
    /// on `prefetchQueue` (wrapping to frame 0 near the loop end). Idempotent per
    /// frame index; cancels any in-flight job whose image left the window; skips
    /// images already cached, in flight, or known-failed. The render thread then
    /// hits the cache instead of decoding synchronously — no loop-seam stutter.
    private func scheduleDecodedImagePrefetch(after frameIndex: Int) {
        // Fold in any completed off-thread decodes first (every tick, even when the
        // frame index is unchanged), so a warm image lands in the cache promptly.
        harvestCompletedPrefetches()
        guard frameIndex != lastScheduledFrameIndex else { return }
        lastScheduledFrameIndex = frameIndex

        let wanted = prefetchImageIDs(after: frameIndex)
        prefetchWantedImageIDs = Set(wanted)

        // Cancel jobs for images that have fallen out of the look-ahead window —
        // bounds the in-flight backlog to the window even under a slow queue.
        // (Collect first; don't mutate `prefetchJobs` while iterating it.)
        let staleImageIDs = prefetchJobs.keys.filter { !prefetchWantedImageIDs.contains($0) }
        for imageID in staleImageIDs {
            prefetchJobs.removeValue(forKey: imageID)?.item.cancel()
        }

        for imageID in wanted {
            guard decodedImageCache[imageID] == nil,
                  prefetchJobs[imageID] == nil,
                  !prefetchFailedImageIDs.contains(imageID),
                  compressedImages.indices.contains(imageID),
                  let mipmap = compressedImages[imageID].payloads.first else { continue }

#if DEBUG
            let delay = debugPrefetchDecodeDelay
#endif
            // The work item captures only Sendable values (the compressed mipmap
            // and its result box), never `self`: it inflates off-thread and writes
            // the decode into the box. The render actor harvests it on a later tick
            // (`harvestCompletedPrefetches`), so nothing non-Sendable crosses here.
            let box = OSAllocatedUnfairLock<PrefetchOutcome>(initialState: .pending)
            let pump = onPrefetchComplete
            let item = DispatchWorkItem { @Sendable in
#if DEBUG
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
#endif
                let decoded = try? Self.decodedBytes(from: mipmap)
                box.withLock { $0 = .done(decoded) }
                // Land the result now (via the owner's isolation hop), not at the
                // next tick — the pre-3c contract the tests lock.
                pump?()
            }
            prefetchJobs[imageID] = (item, box)
            prefetchQueue.async(execute: item)
        }
    }

    /// Moves any completed off-thread prefetch decodes into the cache. Runs in the
    /// owner's isolation — on completion (via `onPrefetchComplete`'s actor hop),
    /// before a synchronous decode, on schedule, and from the debug probes. Stale
    /// results (playback moved past the image, or a decode failure) are dropped
    /// exactly as the old completion did.
    func harvestCompletedPrefetches() {
        guard !prefetchJobs.isEmpty else { return }
        for (imageID, job) in prefetchJobs {
            guard case .done(let decoded) = job.box.withLock({ $0 }) else { continue }
            prefetchJobs.removeValue(forKey: imageID)
            guard let decoded else {
                // A failed decode is recorded so it is never re-scheduled.
                prefetchFailedImageIDs.insert(imageID)
                continue
            }
            // Drop a stale result (playback moved past this image) so it can't
            // LRU-evict the current/next image we actually need.
            guard prefetchWantedImageIDs.contains(imageID), decodedImageCache[imageID] == nil else { continue }
            storeDecodedImage(decoded, for: imageID)
        }
    }

    /// The next `decodedImagePrefetchLookahead` DISTINCT image IDs after
    /// `frameIndex` that aren't already cached, scanning at most one full loop.
    private func prefetchImageIDs(after frameIndex: Int) -> [Int] {
        guard !frames.isEmpty, Self.decodedImagePrefetchLookahead > 0 else { return [] }

        var imageIDs: [Int] = []
        var seen: Set<Int> = []
        for offset in 1...frames.count {
            let rawIndex = frameIndex + offset
            let targetIndex: Int
            if rawIndex < frames.count {
                targetIndex = rawIndex
            } else if loop {
                targetIndex = rawIndex % frames.count
            } else {
                break
            }
            let imageID = frames[targetIndex].imageID
            guard seen.insert(imageID).inserted, decodedImageCache[imageID] == nil else { continue }
            imageIDs.append(imageID)
            if imageIDs.count == Self.decodedImagePrefetchLookahead { break }
        }
        return imageIDs
    }

    private func cancelPrefetch(for imageID: Int) {
        prefetchJobs.removeValue(forKey: imageID)?.item.cancel()
    }

    private func storeDecodedImage(_ decoded: Data, for imageID: Int) {
        decodedImageCache[imageID] = decoded
        touchDecodedImage(imageID)
        evictIfNeeded()
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

    private nonisolated static func decodedBytes(from mipmap: WPETexCompressedMipmap) throws -> Data {
        if mipmap.isCompressed {
            return try inflate(mipmap)
        }
        guard mipmap.compressedBytes.count >= mipmap.decompressedByteCount else {
            throw Failure.truncatedImageBytes
        }
        return mipmap.compressedBytes.prefix(mipmap.decompressedByteCount)
    }

    private nonisolated static func inflate(_ mipmap: WPETexCompressedMipmap) throws -> Data {
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
        // Match the eager loader: RG88 alpha-channel-priority glows sample
        // as (R, R, R, G) so the alpha falloff survives the `.rg8Unorm` upload.
        if alphaChannelPriorityRG88 {
            descriptor.swizzle = MTLTextureSwizzleChannels(red: .red, green: .red, blue: .red, alpha: .green)
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure.textureAllocationFailed
        }
        texture.label = "\(label) lazy frame"
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
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
