#if !LITE_BUILD
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal

/// Phase 2E MP4-in-`.tex` video source. WPE Workshop ships some "video
/// wallpapers" as a `.tex` whose bitmap payload is an MP4 byte run; before
/// 2E those payloads were rejected as `.unsupportedAnimation`.
///
/// The source stages the MP4 bytes into a temp file (Apple's `AVURLAsset`
/// requires a URL on macOS) and runs a dedicated `AVAssetReader` worker on
/// a utility-QoS queue. Each decoded `CMSampleBuffer` becomes an
/// `MTLTexture` via `CVMetalTextureCache` so no CPU copy lands on the main
/// thread.
///
/// Threading model: state behind `NSLock`. The renderer is `@MainActor` and
/// only ever calls `texture(at:)`, `applyPerformanceProfile(_:)`, and
/// `invalidate()` from main; the reader queue advances frames in the
/// background and publishes the latest decoded `MTLTexture` under the same
/// lock.
final class WPEVideoTextureSource: @unchecked Sendable {
    private struct PublishedFrame {
        let texture: MTLTexture
        let cvTexture: CVMetalTexture
        let presentationTime: TimeInterval
    }

    private final class State {
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var latestFrame: PublishedFrame?
        var requestedTime: TimeInterval = 0
        var isRunning = false
        var isSuspended = false
    }

    private let device: MTLDevice
    private let videoURL: URL
    private let asset: AVURLAsset
    private let queue = DispatchQueue(label: "LiveWallpaper.WPEVideoTextureSource.reader", qos: .userInitiated)
    private let lock = NSLock()
    private let state = State()
    private var textureCache: CVMetalTextureCache?

    init(device: MTLDevice, videoURL: URL) throws {
        self.device = device
        self.videoURL = videoURL
        self.asset = AVURLAsset(url: videoURL)

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        self.textureCache = cache
    }

    static func persistVideoData(_ data: Data, cacheDirectory: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            let url = cacheDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            try data.write(to: url, options: [.atomic])
            return url
        }.value
    }

    @MainActor
    func texture(at time: TimeInterval) -> MTLTexture? {
        let shouldStart: Bool
        let latest: MTLTexture?

        lock.lock()
        state.requestedTime = max(time, 0)
        shouldStart = !state.isRunning && !state.isSuspended
        latest = state.latestFrame?.texture
        if shouldStart {
            state.isRunning = true
        }
        lock.unlock()

        if shouldStart {
            queue.async { [weak self] in
                self?.readerLoop()
            }
        }

        return latest
    }

    @MainActor
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        switch profile {
        case .quality:
            lock.withLockGuard { state.isSuspended = false }
        case .suspended:
            lock.withLockGuard { state.isSuspended = true }
            queue.async { [weak self] in
                self?.stopReaderAndFlush()
            }
        }
    }

    @MainActor
    func invalidate() {
        lock.withLockGuard { state.isSuspended = true }
        queue.sync {
            stopReaderAndFlush()
        }
        try? FileManager.default.removeItem(at: videoURL)
    }

    private func readerLoop() {
        defer {
            lock.withLockGuard { state.isRunning = false }
        }

        while true {
            if lock.withLockGuard({ state.isSuspended }) {
                stopReaderAndFlush()
                return
            }

            do {
                try configureReaderIfNeeded()
            } catch {
                stopReaderAndFlush()
                return
            }

            guard let output = lock.withLockGuard({ state.output }) else {
                stopReaderAndFlush()
                return
            }

            guard let sample = output.copyNextSampleBuffer() else {
                restartReaderForLoop()
                continue
            }

            autoreleasepool {
                publish(sampleBuffer: sample)
            }
        }
    }

    private func configureReaderIfNeeded() throws {
        if lock.withLockGuard({ state.reader != nil }) {
            return
        }

        let (track, _) = try Self.loadVideoTrackAndDuration(asset: asset)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw WPEMetalTextureLoaderError.malformedPayload("AVAssetReader cannot add video output")
        }
        reader.add(output)

        let requestedTime = lock.withLockGuard { state.requestedTime }
        if requestedTime > 0 {
            let start = CMTime(seconds: requestedTime, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }

        guard reader.startReading() else {
            throw reader.error ?? WPEMetalTextureLoaderError.malformedPayload("AVAssetReader failed to start")
        }

        lock.lock()
        state.reader = reader
        state.output = output
        lock.unlock()
    }

    /// Bridges the async `AVAsset` API to our sync background reader loop.
    /// The deprecated `tracks(withMediaType:)` + `asset.duration` accessors
    /// would block silently on first access; the modern `loadTracks` /
    /// `load(.duration)` are explicit. We block the reader queue here because
    /// the rest of the loop already pulls samples synchronously — promoting
    /// the loop to async is a wider refactor scheduled for a later phase.
    nonisolated private static func loadVideoTrackAndDuration(asset: AVURLAsset) throws -> (AVAssetTrack, Double) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(AVAssetTrack, Double), Error> =
            .failure(WPEMetalTextureLoaderError.malformedPayload("Asset load did not complete"))

        Task.detached {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    throw WPEMetalTextureLoaderError.malformedPayload("MP4 TEX has no video track")
                }
                let duration = try await asset.load(.duration)
                let seconds = duration.seconds.isFinite ? duration.seconds : 0
                result = .success((track, seconds))
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try result.get()
    }

    private func publish(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let textureCache else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        var status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm_srgb,
            width,
            height,
            0,
            &cvTexture
        )

        if status != kCVReturnSuccess {
            status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
        }

        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let frame = PublishedFrame(
            texture: texture,
            cvTexture: cvTexture,
            presentationTime: pts.isFinite ? pts : 0
        )

        lock.withLockGuard {
            state.latestFrame = frame
        }
    }

    private func restartReaderForLoop() {
        lock.lock()
        state.reader?.cancelReading()
        state.reader = nil
        state.output = nil
        state.requestedTime = 0
        lock.unlock()
    }

    private func stopReaderAndFlush() {
        let cache = textureCache

        lock.lock()
        state.reader?.cancelReading()
        state.reader = nil
        state.output = nil
        state.latestFrame = nil
        lock.unlock()

        if let cache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}

extension WPEVideoTextureSource: WPEDynamicTextureSource {}

private extension NSLock {
    /// Helper avoids shadowing the protocol method `withLock` SwiftSyntax may already have on newer SDKs.
    func withLockGuard<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
