import Foundation

/// A single stereo audio analysis result: 64 normalized frequency bins per
/// channel. This is the sink-agnostic contract shared by every audio-reactive
/// surface — WPE Metal scene uniforms and the HTML
/// `wallpaperRegisterAudioListener` web bridge.
///
/// Bin values are clamped to `0...1` (low frequency → high). Both initializers
/// guarantee exactly `binCount` finite entries per channel so downstream
/// consumers never have to defend against ragged, NaN-laden, or out-of-range
/// input.
struct AudioSpectrumFrame: Equatable, Sendable {
    static let binCount = 64

    static let silence = AudioSpectrumFrame(
        validatedLeft: [Float](repeating: 0, count: binCount),
        validatedRight: [Float](repeating: 0, count: binCount),
        timestampNanos: 0
    )

    let left: [Float]
    let right: [Float]
    let timestampNanos: UInt64

    /// Sanitizing init: clamps each channel to exactly `binCount` finite `0...1`
    /// values. Used off the hot path (`snapshot()` copy-out, tests).
    init(left: [Float], right: [Float], timestampNanos: UInt64) {
        self.left = Self.normalizedBins(left)
        self.right = Self.normalizedBins(right)
        self.timestampNanos = timestampNanos
    }

    /// Fast-path initializer for channels the caller has already produced at the
    /// correct length and range (the DSP processor output). Skips the
    /// per-channel sanitizing copy so the producer can run allocation-free.
    init(validatedLeft: [Float], validatedRight: [Float], timestampNanos: UInt64) {
        self.left = validatedLeft
        self.right = validatedRight
        self.timestampNanos = timestampNanos
    }

    /// The Wallpaper Engine web contract: 128 floats, `[left64, right64]`.
    var wpeWebPayload128: [Float] {
        left + right
    }

    static func normalizedBins(_ bins: [Float]) -> [Float] {
        normalizedBins(bins, count: binCount)
    }

    static func normalizedBins(_ bins: [Float], count: Int) -> [Float] {
        let resolvedCount = max(0, count)
        guard resolvedCount > 0 else { return [] }

        var normalized: [Float] = []
        normalized.reserveCapacity(resolvedCount)

        for value in bins.prefix(resolvedCount) {
            normalized.append(clamp(value))
        }

        if normalized.count < resolvedCount {
            normalized.append(contentsOf: repeatElement(0, count: resolvedCount - normalized.count))
        }

        return normalized
    }

    /// Coerces non-finite values to `0` and clamps finite values into `0...1`.
    static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
