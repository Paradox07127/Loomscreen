#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal

/// One pre-uploaded animation frame: a Metal texture sized to the TEXS
/// sub-rect, plus the source-space sub-rect for debug / asset audit.
/// `duration` is per-frame so variable-rate TEXS schedules don't get
/// flattened to the average frame rate at render time.
///
/// Not declared `Sendable` because `MTLTexture` isn't `Sendable` either;
/// instances always live inside `WPETexAnimatedTextureSource`, which is
/// itself `@MainActor`-isolated, so the frame never crosses an isolation
/// boundary independently.
struct WPETexAnimatedFrame {
    let texture: MTLTexture
    let sourceSubRect: CGRect?
    let duration: TimeInterval
}

/// Phase 2E animated `.tex` source. Each TEXS frame is pre-cropped from
/// its source atlas and uploaded as an independent `MTLTexture`; the
/// runtime selects the current frame from the runtime clock against a
/// per-frame duration timeline so variable-rate schedules play correctly.
///
/// Pre-P0 the loader uploaded the whole atlas as a single frame and
/// `WPETexAnimatedTextureSource` ignored TEXS sub-rects entirely — sprite
/// sheets rendered the whole atlas every frame. P0 introduces per-frame
/// crops while keeping the existing `texture(at:)` consumer contract.
@MainActor
final class WPETexAnimatedTextureSource: WPEDynamicTextureSource {
    private let frames: [WPETexAnimatedFrame]
    private let frameStartTimes: [TimeInterval]
    private let totalDuration: TimeInterval
    private let frameRate: Double
    private let loop: Bool

    init(frames: [WPETexAnimatedFrame], frameRate: Double, loop: Bool) {
        self.frames = frames
        self.frameRate = frameRate > 0 ? frameRate : WPETexAnimationTrack.defaultFrameRate
        self.loop = loop

        let fallbackDuration = 1.0 / self.frameRate
        var cursor: TimeInterval = 0
        var starts: [TimeInterval] = []
        starts.reserveCapacity(frames.count)
        for frame in frames {
            starts.append(cursor)
            cursor += frame.duration > 0 ? frame.duration : fallbackDuration
        }
        self.frameStartTimes = starts
        self.totalDuration = cursor > 0
            ? cursor
            : Double(frames.count) * fallbackDuration
    }

    /// Convenience init used by existing fixtures and tests that don't
    /// carry TEXS sub-rect data. Each entry becomes a fixed-cadence
    /// frame at `1.0 / frameRate`.
    convenience init(frames: [MTLTexture], frameRate: Double, loop: Bool) {
        let safeFrameRate = frameRate > 0 ? frameRate : WPETexAnimationTrack.defaultFrameRate
        let duration = 1.0 / safeFrameRate
        self.init(
            frames: frames.map { texture in
                WPETexAnimatedFrame(texture: texture, sourceSubRect: nil, duration: duration)
            },
            frameRate: safeFrameRate,
            loop: loop
        )
    }

    func texture(at time: TimeInterval) -> MTLTexture? {
        guard !frames.isEmpty else { return nil }
        return frames[frameIndex(at: time)].texture
    }

    func frameIndex(at time: TimeInterval) -> Int {
        guard !frames.isEmpty else { return 0 }
        let bounded: TimeInterval
        if loop {
            let positive = max(time, 0)
            bounded = totalDuration > 0
                ? positive.truncatingRemainder(dividingBy: totalDuration)
                : 0
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
    }
}
#endif
