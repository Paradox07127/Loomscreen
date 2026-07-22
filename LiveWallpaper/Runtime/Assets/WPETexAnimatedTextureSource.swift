#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

/// A pre-uploaded TEXS animation frame with source bounds and variable-frame duration.
/// It remains within its renderer isolation domain because `MTLTexture` is not `Sendable`.
struct WPETexAnimatedFrame {
    let texture: MTLTexture
    let sourceSubRect: CGRect?
    let duration: TimeInterval
}

/// Plays variable-duration TEXS frames from shared atlas textures.
/// Shader consumers use normalized frame rectangles to select atlas regions.
// Not `@MainActor`: lives inside the renderer's actor isolation.
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

    /// Sub-rect-less path (fixtures/tests): each entry becomes a fixed-cadence
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

    /// TEXS frame rate, surfaced for particle sprite sheets built from the
    /// `.tex` animation track (no `.tex-json` sidecar).
    var spriteSheetFrameRate: Double { frameRate }

    /// Per-frame sub-rects normalized to `[0, 1]` UV against the atlas
    /// dimensions, for particle sprite-sheet slicing. Returns `[]` if any
    /// frame lacks a sub-rect (the whole-atlas / single-frame case).
    func spriteSheetFrameRectsNormalized() -> [SIMD4<Float>] {
        guard !frames.isEmpty else { return [] }
        var rects: [SIMD4<Float>] = []
        rects.reserveCapacity(frames.count)
        for frame in frames {
            guard let rect = frame.sourceSubRect else { return [] }
            let atlasWidth = CGFloat(max(frame.texture.width, 1))
            let atlasHeight = CGFloat(max(frame.texture.height, 1))
            rects.append(SIMD4<Float>(
                Float(rect.minX / atlasWidth), Float(rect.minY / atlasHeight),
                Float(rect.maxX / atlasWidth), Float(rect.maxY / atlasHeight)
            ))
        }
        return rects
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
