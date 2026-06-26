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
/// Pacing uses `AVPlayer` so frames schedule against the same host clock as
/// the Metal pipeline. Frames are tapped via a player-level `AVPlayerVideoOutput`
/// on macOS 15+ (gapless across the looper's item rotations) and an
/// `AVPlayerItemVideoOutput` on the macOS 14 fallback.
///
/// Pixel format prefers `.bgra8Unorm_srgb` to match
/// `WPEMetalRenderExecutor.outputPixelFormat`, with `.bgra8Unorm` as the
/// fallback when the GPU rejects the sRGB variant.
///
/// Lifecycle: the player stays paused after `init`; the renderer's
/// `applyPerformanceProfile(currentProfile)` (called once textures
/// finish loading) decides whether to start it, which also respects a
/// pre-load `.suspended` profile.
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
    /// The on-disk staging file backing this source. Handled in
    /// `invalidate()`: released to `WPEVideoTextureDiskCache` (kept for reuse)
    /// when `onInvalidate` is supplied, otherwise deleted.
    private let cleanupURL: URL?
    /// Invoked with `cleanupURL` on invalidate when the file is owned by the
    /// disk cache — the cache keeps it for reuse and reclaims it via LRU/GC.
    /// `nil` (e.g. in tests that stage a throwaway temp file) restores the
    /// legacy "unlink the temp file on invalidate" behavior.
    private let onInvalidate: (@Sendable (URL) -> Void)?
    /// `AVPlayerLooper` mints a fresh `AVPlayerItem` per loop iteration;
    /// `videoOutput` can only be attached to one item at a time, so we
    /// remove it from the previous item before adding it to the new one.
    private weak var attachedOutputItem: AVPlayerItem?
    /// macOS 15+ player-level output (`WPEPlayerLevelVideoOutput`), held as
    /// `AnyObject` so the stored property stays valid on the macOS 14 deployment
    /// floor. When set, `texture(at:)` pulls frames from it and the item-level
    /// `videoOutput` + KVO-rebind path is bypassed — a player-level output spans
    /// the looper's item rotations itself, so the loop wraps with no reattach gap.
    private var playerLevelOutput: AnyObject?
    /// Presentation time of the last frame published from the player-level
    /// output, so a frame held across several render ticks isn't re-wrapped into
    /// a fresh `CVMetalTexture` every tick (the player-level equivalent of the
    /// item path's `hasNewPixelBuffer` guard).
    private var lastPlayerLevelPresentationTime: CMTime?
    private var latest: PublishedFrame?
    private var isInvalidated = false

    private struct PublishedFrame {
        let texture: MTLTexture
        let cvTexture: CVMetalTexture
    }

    init(
        device: MTLDevice,
        videoURL: URL,
        onInvalidate: (@Sendable (URL) -> Void)? = nil
    ) throws {
        self.cleanupURL = videoURL
        self.onInvalidate = onInvalidate

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
        // Let the player briefly ensure the next looped item's frames are ready
        // before resuming at the loop point, instead of playing through the
        // handoff with a sparse decode (the "slow-motion" at the wrap). The asset
        // is RAM-resident, so this wait is effectively instant — no visible pause.
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        queuePlayer.isMuted = true
        queuePlayer.volume = 0
        self.player = queuePlayer

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: Self.outputPixelBufferAttributes)
        output.suppressesPlayerRendering = true
        self.videoOutput = output

        // macOS 15+: a player-level `AVPlayerVideoOutput` spans the looper's item
        // rotations itself, so the loop wraps with no detach/reattach gap. Attach
        // it BEFORE the looper enqueues items so the output is associated with the
        // player up front and selects data channels consistently across every
        // looped item (the SDK recommends setting `videoOutput` before items).
        if #available(macOS 15.0, *) {
            self.playerLevelOutput = WPEPlayerLevelVideoOutput(player: queuePlayer)
        }

        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)

        // macOS 14 fallback: bind the item-level output, reattached on demand in
        // `texture(at:)`. Playback stays paused — the renderer drives play/pause
        // via `applyPerformanceProfile`.
        if #unavailable(macOS 15.0) {
            attachOutputIfNeeded(to: queuePlayer.currentItem ?? playerItem)
        }
    }

    func texture(at time: TimeInterval) -> MTLTexture? {
        _ = time   // Wall-clock pacing comes from AVPlayer, not the scene clock.
        guard !isInvalidated else { return nil }

        // Play-once for a script-controlled source. Rather than mutate the
        // AVPlayerLooper queue (which races the frame tap), detect the natural
        // loop wrap — the looper restarts a fresh item at ~0 — and freeze: pause
        // and keep returning the last frame published before the wrap. The
        // script then fades/hides the layer. Script-initiated seeks (replay) reset
        // this via `resetScriptPlayback()`.
        if scriptControlled {
            if scriptHeldAtEnd { return latest?.texture }
            let playhead = playheadSeconds
            if playhead + 0.1 < scriptLastPlaybackSeconds {
                player.pause()
                scriptHeldAtEnd = true
                Logger.notice("[LayerScript] video froze at loop wrap (playhead \(String(format: "%.2f", scriptLastPlaybackSeconds))s→\(String(format: "%.2f", playhead))s) — play-once", category: .wpeRender)
                return latest?.texture   // hold the pre-wrap (≈ last) frame
            }
            scriptLastPlaybackSeconds = playhead
        }

        if #available(macOS 15.0, *), let playerOutput = playerLevelOutput as? WPEPlayerLevelVideoOutput {
            if let frame = playerOutput.currentFrame(),
               lastPlayerLevelPresentationTime.map({ CMTimeCompare($0, frame.presentationTime) != 0 }) ?? true {
                publish(pixelBuffer: frame.pixelBuffer)
                lastPlayerLevelPresentationTime = frame.presentationTime
            }
            return latest?.texture
        }

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
            // A script-owned source decides its own playback (e.g. an intro that
            // plays once); don't force-play it back to life on a policy resume.
            if !scriptControlled { player.play() }
        case .suspended:
            player.pause()
        }
    }

    // MARK: - SceneScript playback control (`thisLayer.getVideoTexture()`)

    /// Set once a layer SceneScript takes over playback, so the performance
    /// policy stops force-playing this source (see `applyPerformanceProfile`),
    /// and `texture(at:)` switches to play-once (freeze on the natural loop wrap).
    private var scriptControlled = false
    /// Last observed playhead, to detect the loop wrap (playhead jumps backward).
    private var scriptLastPlaybackSeconds: TimeInterval = 0
    /// True once the single play reached its end and the source froze on the last
    /// frame. Cleared by a script-initiated seek/replay.
    private var scriptHeldAtEnd = false

    private func enterScriptControlledMode() {
        guard !scriptControlled else { return }
        scriptControlled = true
        resetScriptPlayback()
    }

    /// A fresh play-through: clear the freeze and the wrap baseline so the next
    /// natural wrap (not this intentional start) triggers the freeze.
    private func resetScriptPlayback() {
        scriptHeldAtEnd = false
        scriptLastPlaybackSeconds = playheadSeconds
    }

    func scriptPlay() {
        guard !isInvalidated else { return }
        enterScriptControlledMode()
        resetScriptPlayback()
        player.play()
    }

    func scriptPause() {
        guard !isInvalidated else { return }
        enterScriptControlledMode()
        player.pause()
    }

    /// Pause and rewind to the first frame (resets the play-once state for replay).
    func scriptStop() {
        guard !isInvalidated else { return }
        enterScriptControlledMode()
        player.pause()
        player.seek(to: .zero)
        resetScriptPlayback()
    }

    func scriptSetCurrentTime(_ seconds: TimeInterval) {
        guard !isInvalidated else { return }
        enterScriptControlledMode()
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        resetScriptPlayback()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        if #available(macOS 15.0, *), let playerOutput = playerLevelOutput as? WPEPlayerLevelVideoOutput {
            playerOutput.detach()
        }
        playerLevelOutput = nil
        lastPlayerLevelPresentationTime = nil
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
            if let onInvalidate {
                onInvalidate(cleanupURL)
            } else {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
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
        latest = PublishedFrame(texture: texture, cvTexture: cvTexture)
    }

    /// 2s forward buffer — bytes are already in RAM via the in-memory
    /// resource loader, so longer buffers gain nothing while costing peak
    /// decoder state.
    private static let bufferHintSeconds: TimeInterval = 2

    /// Pixel-buffer attributes for the BGRA Metal-compatible video output. Typed
    /// as `[String: any Sendable]` (every value — `OSType`, `Bool`, empty dict —
    /// is `Sendable`) so the dictionary is itself `Sendable` and the
    /// strict-concurrency call-site warning on the `AVPlayerItemVideoOutput` init
    /// goes away; it converts to the API's `[String: Any]` at the call.
    private static let outputPixelBufferAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
    ]

    /// Dedicated queue for the in-memory resource-loader delegate, mirroring
    /// `WallpaperVideoPlayer`'s pattern so byte-range fulfilment never lands
    /// on main.
    private static let resourceLoaderQueue = DispatchQueue(
        label: "app.livewallpaper.wpe.video.in-memory-loader",
        qos: .userInitiated
    )

    /// Underlying player's current item time, in seconds (0 when invalid). Used
    /// by the script-controlled play-once wrap detection in `texture(at:)`, so it
    /// must exist in all build configs (not just DEBUG).
    private var playheadSeconds: TimeInterval {
        let time = player.currentTime()
        guard time.isValid, !time.isIndefinite else { return 0 }
        let seconds = time.seconds
        return seconds.isFinite ? seconds : 0
    }

    // MARK: - Testing seam

    #if DEBUG
    /// Underlying player's current item time, in seconds. Exposed for pacing
    /// tests (e.g. "after 250 ms wall-clock the player advanced ~250 ms").
    var currentItemPlaybackSeconds: TimeInterval { playheadSeconds }
    #endif
}

extension WPEVideoTextureSource: WPEDynamicTextureSource {}

/// macOS 15+ player-level video frame tap. Unlike `AVPlayerItemVideoOutput`
/// (bound to a single `AVPlayerItem`), `AVPlayerVideoOutput` is attached to the
/// player and keeps vending frames across the looper's item rotations with no
/// detach/reattach — eliminating the loop-seam freeze. Output is pinned to
/// 32BGRA so the existing `CVMetalTextureCacheCreateTextureFromImage` path
/// (`.bgra8Unorm[_srgb]`) is unchanged.
@available(macOS 15.0, *)
@MainActor
private final class WPEPlayerLevelVideoOutput {
    private let output: AVPlayerVideoOutput
    private weak var player: AVQueuePlayer?

    init(player: AVQueuePlayer) {
        let specification = AVVideoOutputSpecification(tagCollections: [.monoscopicForVideoOutput()])
        // Pin the output to 32BGRA so `publish(pixelBuffer:)`'s
        // `.bgra8Unorm[_srgb]` texture path is unchanged. `defaultOutputSettings`
        // applies to every tag collection without an explicit mapping; it is
        // `NS_SWIFT_SENDABLE`, so the dictionary is typed as `any Sendable`.
        let outputSettings: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
        ]
        specification.defaultOutputSettings = outputSettings
        let output = AVPlayerVideoOutput(specification: specification)
        player.videoOutput = output
        self.output = output
        self.player = player
    }

    /// The frame for the current host time, or `nil` when none is ready yet
    /// (the caller keeps showing the last published frame).
    func currentFrame() -> (pixelBuffer: CVPixelBuffer, presentationTime: CMTime)? {
        guard let sample = output.taggedBuffers(
            forHostTime: CMClockGetTime(.hostTimeClock)
        ) else {
            return nil
        }
        for tagged in sample.taggedBufferGroup {
            if case let .pixelBuffer(pixelBuffer) = tagged.buffer {
                return (pixelBuffer, sample.presentationTime)
            }
        }
        return nil
    }

    func detach() {
        player?.videoOutput = nil
    }
}
#endif
