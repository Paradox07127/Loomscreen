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
/// and the WPE Windows shader math). Sampling these textures as `_srgb`
/// would compound with the output attachment's sRGB encode on the way out
/// and produce the "over-exposed" appearance seen on video-backed scenes.
@MainActor
final class WPEVideoTextureSource {
    private let device: MTLDevice
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
    /// we need to attach `videoOutput` to each one. Weak-set so completed
    /// items can be reclaimed without manual bookkeeping.
    private let observedItems = NSHashTable<AVPlayerItem>.weakObjects()
    private var latest: PublishedFrame?

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
        self.device = device
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

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        output.suppressesPlayerRendering = true
        self.videoOutput = output

        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)

        // Bind the output to the looper's first concrete item; subsequent
        // rotations are caught by `attachOutputIfNeeded` on each
        // `texture(at:)` call.
        attachOutputIfNeeded(to: queuePlayer.currentItem ?? playerItem)
        queuePlayer.play()
    }

    func texture(at time: TimeInterval) -> MTLTexture? {
        _ = time   // Wall-clock pacing comes from AVPlayer, not the scene clock.
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
        switch profile {
        case .quality:
            player.play()
        case .suspended:
            player.pause()
        }
    }

    func invalidate() {
        player.pause()
        player.removeAllItems()
        latest = nil
        CVMetalTextureCacheFlush(textureCache, 0)
        if let cleanupURL {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
    }

    // MARK: - Internals

    private func attachOutputIfNeeded(to item: AVPlayerItem?) {
        guard let item, !observedItems.contains(item) else { return }
        item.add(videoOutput)
        observedItems.add(item)
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
}

extension WPEVideoTextureSource: WPEDynamicTextureSource {}
#endif
