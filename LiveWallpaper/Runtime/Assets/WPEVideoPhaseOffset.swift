#if !LITE_BUILD
import AVFoundation
import CoreGraphics
import Foundation

/// Estimates the playback offset between an intro overlay and its free-running loop
/// by cross-correlating downsampled frames, enabling a phase-aligned crossfade.
enum WPEVideoPhaseOffset {
    private static let sampleWidth = 64
    private static let sampleHeight = 36

    /// Best lag (seconds) such that `intro@t` best matches `loop@(t+lag)`.
    /// Returns nil when frames can't be decoded or the match is too weak to trust.
    static func measure(introURL: URL, loopURL: URL) async -> TimeInterval? {
        let introAsset = AVURLAsset(url: introURL)
        let loopAsset = AVURLAsset(url: loopURL)
        guard let introDur = try? await introAsset.load(.duration).seconds,
              let loopDur = try? await loopAsset.load(.duration).seconds,
              introDur > 1, loopDur > 1 else { return nil }

        // Sample the intro's LATTER portion only. A camera-move intro (e.g. a
        // dolly/pull-back) is geometrically different from the loop early on, so
        // those frames never match and just flatten the correlation; by the end the
        // camera has settled to the loop's framing — and the end IS the handoff
        // region we must align. The loop is sampled on a fine grid across its whole
        // cycle so any candidate lag maps to a near frame.
        let introStart = max(1.0, introDur - 5.0)
        let introTimes = Array(stride(from: introStart, through: introDur - 0.5, by: 0.75))
        let loopStep = 0.5
        let loopTimes = Array(stride(from: 0.0, to: loopDur, by: loopStep))
        guard introTimes.count >= 3,
              let introFrames = await grayFrames(introAsset, times: introTimes),
              let loopFrames = await grayFrames(loopAsset, times: loopTimes),
              introFrames.count == introTimes.count,
              loopFrames.count == loopTimes.count else { return nil }

        return bestLag(
            introTimes: introTimes, introFrames: introFrames,
            loopFrames: loopFrames, loopStep: loopStep, loopDuration: loopDur
        )
    }

    /// Pure cross-correlation: the lag minimizing total frame difference between
    /// `intro@t` and `loop@(t+lag)`, or nil when no lag wins by a clear margin
    /// (the videos are unrelated). Separated from frame IO so it's unit-testable.
    static func bestLag(
        introTimes: [Double],
        introFrames: [[Float]],
        loopFrames: [[Float]],
        loopStep: Double,
        loopDuration: Double,
        maxLag: Double = 8.0
    ) -> TimeInterval? {
        guard introTimes.count == introFrames.count, !loopFrames.isEmpty,
              loopStep > 0, loopDuration > 0 else { return nil }
        let lagLimit = min(loopDuration, maxLag)
        var lags: [Double] = []
        var scores: [Double] = []
        var lag = -lagLimit
        while lag <= lagLimit + 1e-9 {
            var total = 0.0
            for (i, t) in introTimes.enumerated() {
                let wrapped = (((t + lag).truncatingRemainder(dividingBy: loopDuration)) + loopDuration)
                    .truncatingRemainder(dividingBy: loopDuration)
                let idx = min(max(Int((wrapped / loopStep).rounded()), 0), loopFrames.count - 1)
                total += mae(introFrames[i], loopFrames[idx])
            }
            lags.append(lag)
            scores.append(total / Double(introTimes.count))
            lag += 0.25
        }
        guard let bestIdx = scores.indices.min(by: { scores[$0] < scores[$1] }) else { return nil }
        let bestLag = lags[bestIdx]
        let bestScore = scores[bestIdx]
        // Confidence: the trough at `bestLag` must be clearly deeper than the
        // landscape FAR from it. Comparing against the immediate neighbor is wrong
        // — near the optimum adjacent lags alias to the same frame and tie. A flat
        // landscape (unrelated videos) has no deeper-than-background trough → nil.
        // A periodic loop may match at several phases (background ≈ 0); any is a
        // valid alignment, so accept the best.
        let background = zip(lags, scores).filter { abs($0.0 - bestLag) > 1.5 }.map(\.1).min()
        if let background, background > 1e-6, bestScore >= background * 0.9 { return nil }
        return bestLag
    }

    private static func mae(_ a: [Float], _ b: [Float]) -> Double {
        var sum = 0.0
        for i in 0..<min(a.count, b.count) { sum += Double(abs(a[i] - b[i])) }
        return sum / Double(max(min(a.count, b.count), 1))
    }

    private static func grayFrames(_ asset: AVAsset, times: [Double]) async -> [[Float]]? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: sampleWidth, height: sampleHeight)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        var byTime: [Int: [Float]] = [:]
        let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        for await result in generator.images(for: cmTimes) {
            guard case let .success(requestedTime, image, _) = result else { continue }
            byTime[Int((requestedTime.seconds * 1000).rounded())] = gray(image)
        }
        let frames = times.compactMap { byTime[Int(($0 * 1000).rounded())] }
        return frames.count == times.count ? frames : nil
    }

    private static func gray(_ image: CGImage) -> [Float] {
        let w = sampleWidth, h = sampleHeight
        var buffer = [UInt8](repeating: 0, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = buffer.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer.map(Float.init)
    }
}
#endif
