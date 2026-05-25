#if !LITE_BUILD
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// MP4-in-`.tex` video source. WPE Workshop ships some "video wallpapers"
/// as a `.tex` whose bitmap payload is an MP4 byte run; this type plays
/// that MP4 back on the wall clock and hands the renderer the current
/// frame as a Metal texture.
///
/// Pacing comes from `AVPlayer` + `AVPlayerItemVideoOutput` rather than a
/// `while true { copyNextSampleBuffer() }` over `AVAssetReader`. The old
/// path was an offline-decode API used as a playback engine, so it ran as
/// fast as the CPU/GPU could decode — 24 FPS clips perceived as 8× speed,
/// 60 FPS clips as 3×. `AVPlayer` schedules frames against the same host
/// clock that drives the on-screen Metal pipeline, so the output is
/// in-sync with WPE's reference renderer.
///
/// Pixel format is raw `.bgra8Unorm` — the Metal scene pipeline runs in
/// raw RGBA8 author space (matches Almamu's reference linux-wallpaperengine
/// and the WPE Windows shader math). Sampling these as `_srgb` would
/// compound with the output attachment's sRGB encode on the way out and
/// produce the "over-exposed" appearance seen on video-backed scenes.
///
/// Lifecycle: the player stays paused after `init` so the renderer's
/// `applyPerformanceProfile(currentProfile)` (called once textures finish
/// loading) decides whether to start it. Starting in `init` would let the
/// video drift ahead of the rest of the scene's first-frame setup and
/// would also ignore a pre-load `.suspended` profile.
@MainActor
final class WPEVideoTextureSource {
    private let textureCache: CVMetalTextureCache
    private let player: AVQueuePlayer
    private let videoOutput: AVPlayerItemVideoOutput
    /// Retained for the lifetime of the source — `AVPlayerLooper` releases
    /// the looped item rotation if it deallocates.
    private let playerLooper: AVPlayerLooper
    /// `AVAssetResourceLoader.setDelegate(_:queue:)` keeps only a weak
    /// reference; we hold the loader so the in-memory bytes survive.
    private let inMemoryAssetLoader: InMemoryVideoAssetLoader?
    /// The on-disk staging file written by `persistVideoData`. Removed in
    /// `invalidate()` so we don't leak temp `.mp4`s across scene swaps.
    private let cleanupURL: URL?
    /// `AVPlayerLooper` mints a fresh `AVPlayerItem` per loop iteration;
    /// `videoOutput` can only be attached to one item at a time, so we
    /// remove it from the previous item before adding it to the new one.
    private weak var attachedOutputItem: AVPlayerItem?
    private var latest: PublishedFrame?
    private var isInvalidated = false

    private struct PublishedFrame {
        let texture: MTLTexture
        let cvTexture: CVMetalTexture
    }

    nonisolated static func persistVideoData(_ data: Data, cacheDirectory: URL) async throws -> URL {
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

    init(device: MTLDevice, videoURL: URL) throws {
        self.cleanupURL = videoURL

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        self.textureCache = cache

        let assetOptions: [String: Any] = [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            AVURLAssetAllowsCellularAccessKey: false,
            AVURLAssetAllowsExpensiveNetworkAccessKey: false,
            AVURLAssetAllowsConstrainedNetworkAccessKey: false
        ]
        let activeURL: URL
        let loader: InMemoryVideoAssetLoader?
        do {
            let result = try InMemoryVideoAssetLoader.load(from: videoURL)
            loader = result.loader
            activeURL = result.customURL
        } catch {
            loader = nil
            activeURL = videoURL
        }
        self.inMemoryAssetLoader = loader

        let asset = AVURLAsset(url: activeURL, options: assetOptions)
        if let loader {
            asset.resourceLoader.setDelegate(loader, queue: Self.resourceLoaderQueue)
        }

        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = Self.bufferHintSeconds
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        let queuePlayer = AVQueuePlayer()
        queuePlayer.actionAtItemEnd = .none
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        queuePlayer.isMuted = true
        queuePlayer.volume = 0
        self.player = queuePlayer

        let attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        output.suppressesPlayerRendering = true
        self.videoOutput = output

        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)

        // Bind the output to the looper's first concrete item; later
        // rotations land via `attachOutputIfNeeded` on each `texture(at:)`
        // call. Playback stays paused — the renderer drives play/pause
        // through `applyPerformanceProfile`.
        attachOutputIfNeeded(to: queuePlayer.currentItem ?? playerItem)
    }

    func texture(at time: TimeInterval) -> MTLTexture? {
        _ = time   // Wall-clock pacing comes from AVPlayer, not the scene clock.
        guard !isInvalidated else { return nil }
        attachOutputIfNeeded(to: player.currentItem)

        let host = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: host)
        guard itemTime.isValid else { return latest?.texture }

        if videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
           let pixelBuffer = videoOutput.copyPixelBuffer(
               forItemTime: itemTime,
               itemTimeForDisplay: nil
           ) {
            publish(pixelBuffer: pixelBuffer)
        }
        return latest?.texture
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        guard !isInvalidated else { return }
        switch profile {
        case .quality:
            player.play()
        case .suspended:
            player.pause()
        }
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        playerLooper.disableLooping()
        player.pause()
        if let item = attachedOutputItem {
            item.remove(videoOutput)
            attachedOutputItem = nil
        }
        player.removeAllItems()
        latest = nil
        CVMetalTextureCacheFlush(textureCache, 0)
        if let cleanupURL {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
    }

    // MARK: - Internals

    private func attachOutputIfNeeded(to item: AVPlayerItem?) {
        guard let item, item !== attachedOutputItem else { return }
        if let previous = attachedOutputItem {
            previous.remove(videoOutput)
        }
        item.add(videoOutput)
        attachedOutputItem = item
    }

    private func publish(pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
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
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return
        }
        latest = PublishedFrame(texture: texture, cvTexture: cvTexture)
    }

    /// 2s forward buffer — bytes are already in RAM via the in-memory
    /// resource loader, so longer buffers gain nothing while costing peak
    /// decoder state.
    private static let bufferHintSeconds: TimeInterval = 2

    /// Dedicated queue for the in-memory resource-loader delegate, mirroring
    /// `WallpaperVideoPlayer`'s pattern so byte-range fulfilment never lands
    /// on main.
    private static let resourceLoaderQueue = DispatchQueue(
        label: "app.livewallpaper.wpe.video.in-memory-loader",
        qos: .userInitiated
    )

    // MARK: - Testing seam

    #if DEBUG
    /// Underlying player's current item time, in seconds. Exposed for
    /// pacing tests that need to assert "after 250 ms wall-clock the player
    /// has advanced ~250 ms, not 5 seconds" — i.e. that we're not back on
    /// the old `AVAssetReader` unpaced loop.
    var currentItemPlaybackSeconds: TimeInterval {
        let time = player.currentTime()
        guard time.isValid, !time.isIndefinite else { return 0 }
        let seconds = time.seconds
        return seconds.isFinite ? seconds : 0
    }
    #endif
}

extension WPEVideoTextureSource: WPEDynamicTextureSource {}
#endif
