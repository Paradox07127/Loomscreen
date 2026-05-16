#if !LITE_BUILD
import Foundation
import Metal

/// Phase 2E animated `.tex` source. Frames are pre-uploaded as independent
/// `MTLTexture`s during `WPEMetalTextureLoader.makeAnimatedTextureSource`;
/// the runtime simply selects the current frame from the runtime clock.
///
/// `frameIndex(at:)` keeps the math deterministic so tests can pin the
/// 25 FPS WPE convention (40 ms cadence) without involving Metal at all.
@MainActor
final class WPETexAnimatedTextureSource: WPEDynamicTextureSource {
    private let frames: [MTLTexture]
    private let frameRate: Double
    private let loop: Bool

    init(frames: [MTLTexture], frameRate: Double, loop: Bool) {
        self.frames = frames
        self.frameRate = frameRate > 0 ? frameRate : WPETexAnimationTrack.defaultFrameRate
        self.loop = loop
    }

    func texture(at time: TimeInterval) -> MTLTexture? {
        guard !frames.isEmpty else { return nil }
        return frames[frameIndex(at: time)]
    }

    func frameIndex(at time: TimeInterval) -> Int {
        guard !frames.isEmpty else { return 0 }
        let rawIndex = Int(floor(max(time, 0) * frameRate))
        if loop {
            let bounded = rawIndex % frames.count
            return bounded >= 0 ? bounded : bounded + frames.count
        }
        return min(rawIndex, frames.count - 1)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        // Animated TEX frames are pre-uploaded GPU textures. There is no
        // decoder worker to pause; renderer-level references control release.
        _ = profile
    }

    func invalidate() {
        // No explicit Metal release hook. Clearing renderer references on
        // `cleanup()` / `reload()` releases the underlying textures.
    }
}
#endif
