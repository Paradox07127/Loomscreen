#if !LITE_BUILD && DIRECT_DISTRIBUTION
import CoreGraphics
import Foundation
import ImageIO

/// A decoded Workshop preview, either a single still or a bounded animation.
/// `@unchecked Sendable`: the wrapped `CGImage` / `WorkshopAnimatedGIF` are
/// only ever read, never mutated, so they cross actor boundaries safely.
enum WorkshopPreviewAsset: @unchecked Sendable {
    case staticImage(CGImage)
    case animatedGIF(WorkshopAnimatedGIF)

    var posterFrame: CGImage {
        switch self {
        case .staticImage(let image): return image
        case .animatedGIF(let gif): return gif.posterFrame
        }
    }

    var isAnimated: Bool {
        if case .animatedGIF = self { return true }
        return false
    }
}

/// A GIF/APNG decoded under strict memory + CPU budgets. The poster frame is
/// decoded eagerly; remaining frames are produced lazily via `frame(at:)`.
/// `CGImageSourceCreateImageAtIndex` is free-threaded, so `frame(at:)` is safe
/// to call off the main actor (hence the `@unchecked Sendable` conformance).
struct WorkshopAnimatedGIF: @unchecked Sendable {
    let posterFrame: CGImage
    let frameCount: Int
    /// Per-frame display duration, floored at the 30 FPS playback cap.
    let frameDelays: [TimeInterval]

    private let source: CGImageSource

    /// Reject inputs whose raw bytes exceed the loader's transfer cap. Kept in
    /// sync with `WorkshopPreviewImageLoader.maxBytes` — Workshop animated GIF
    /// previews routinely run 8–24 MiB, so an 8 MiB cap silently blanked them.
    static let maxBytes = 32 * 1024 * 1024
    /// Animate at most this many frames; longer animations degrade to a static
    /// poster (we never drop the preview entirely just because it's long).
    static let maxFrameCount = 120
    /// Total decoded-pixel budget (RGBA bytes) across all frames before an
    /// animation degrades to its static poster.
    static let maxDecodedPixelBytes = 96 * 1024 * 1024
    /// 30 FPS playback cap to bound CPU on long-running grids.
    static let minFrameDelay: TimeInterval = 0.033

    func frame(at index: Int) -> CGImage? {
        guard index >= 0, index < frameCount else { return nil }
        if index == 0 { return posterFrame }
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }
}

extension WorkshopAnimatedGIF {

    /// Decodes `data` into a static or animated asset, enforcing every cap.
    /// Returns `nil` on decode failure or any budget violation.
    static func make(from data: Data) -> WorkshopPreviewAsset? {
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(source)
        // Read dimensions from metadata (no full decode) and reject before
        // materializing the poster — guards against decompression bombs where
        // a small compressed file expands to gigabytes of pixels. The bomb
        // guard is applied to the SINGLE poster frame so a high-res still is
        // never rejected for its frame count.
        guard count > 0,
              let dimensions = imageDimensions(from: source, index: 0),
              isWithinPixelBudget(width: dimensions.width, height: dimensions.height, frameCount: 1),
              let poster = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        // Animate only within the frame-count + total decoded-pixel budgets;
        // otherwise degrade to the static poster rather than showing nothing.
        // (A long or large animated preview previously returned nil → blank.)
        guard count > 1,
              count <= maxFrameCount,
              isWithinPixelBudget(width: dimensions.width, height: dimensions.height, frameCount: count) else {
            return .staticImage(poster)
        }

        return .animatedGIF(
            WorkshopAnimatedGIF(
                posterFrame: poster,
                frameCount: count,
                frameDelays: readFrameDelays(from: source, frameCount: count),
                source: source
            )
        )
    }

    /// Overflow-safe RGBA-footprint check (`width·height·4·frameCount`).
    /// Staged `UInt64` divisions keep a maliciously large image from
    /// trapping on `Int` multiplication overflow.
    static func isWithinPixelBudget(width: Int, height: Int, frameCount: Int) -> Bool {
        guard width > 0, height > 0, frameCount > 0 else { return false }
        let w = UInt64(width), h = UInt64(height), n = UInt64(frameCount)
        guard w <= UInt64.max / h else { return false }
        let pixelsPerFrame = w * h
        guard pixelsPerFrame <= UInt64.max / n else { return false }
        let totalPixels = pixelsPerFrame * n
        guard totalPixels <= UInt64.max / 4 else { return false }
        return totalPixels * 4 <= UInt64(maxDecodedPixelBytes)
    }

    /// Pixel dimensions straight from the source metadata — cheap, no decode.
    static func imageDimensions(from source: CGImageSource, index: Int) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue else {
            return nil
        }
        return (width, height)
    }

    static func readFrameDelays(from source: CGImageSource, frameCount: Int) -> [TimeInterval] {
        (0..<frameCount).map { index in
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else {
                return 0.1
            }
            if let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue, unclamped > 0 {
                    return max(unclamped, minFrameDelay)
                }
                if let delay = (gif[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, minFrameDelay)
                }
            }
            if let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
                if let delay = (png[kCGImagePropertyAPNGUnclampedDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, minFrameDelay)
                }
                if let delay = (png[kCGImagePropertyAPNGDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, minFrameDelay)
                }
            }
            return 0.1
        }
    }
}
#endif
