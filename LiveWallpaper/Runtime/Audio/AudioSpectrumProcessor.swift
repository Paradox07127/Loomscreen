import Accelerate
import Foundation

/// Reusable stereo FFT → 64-bin spectrum processor. Buffers are preallocated and
/// reused so steady-state processing performs no heap allocation, allowing it to
/// run directly on a Core Audio IOProc or ScreenCaptureKit sample queue.
///
/// Channels are kept separate (no mono collapse). Bands are LOG-spaced across
/// [lowFrequency, highFrequency] with a treble EQ boost, then each band is
/// dB-normalized with attack/release temporal smoothing — matching Wallpaper
/// Engine's lively full-range bars instead of the bass-only twitch a linear
/// binning produced. Silence still decays to an exact flat line (noise floor
/// maps to 0), like WPE's muted state.
///
/// Incoming callback buffers are usually smaller than `fftSize` (devices deliver
/// 256–1024 frames). The input buffers act as a sliding window: each call shifts
/// history left and appends the new samples at the tail, so the FFT always sees a
/// full window instead of a zero-padded fragment.
final class AudioSpectrumProcessor {
    struct Configuration: Equatable, Sendable {
        var fftSize: Int = 2048
        var binCount: Int = 64
        // dB→[0,1] mapping window. Calibrated against the WPE RenderDoc oracle
        // (3470764447): WPE's captured spectrum has mean≈0.45 with a WIDE
        // per-bar spread (std≈0.25) — that bin-to-bin height CONTRAST is what
        // reads as "lively/jumpy". The old wide [-80,-12] window (68 dB)
        // compressed a music frame into a flat 0.7–0.9 block (std≈0.07): bars lit
        // but barely differing. This narrower 32 dB window steepens the curve so
        // small dB differences become visible height differences — on the same
        // synthetic music frame std rises to ≈0.22, matching WPE. `noiseFloor`
        // below still gates silence to 0, so a muted scene stays a flat line.
        var minDB: Float = -56
        var maxDB: Float = -24
        var gain: Float = 0.8
        var noiseFloor: Float = 0.002
        var attackTime: Float = 0.045
        // Snappier fall (was 0.180) so bars visibly DROP between transients
        // instead of hanging — measured ~26% more per-frame motion at 0.090,
        // still slow enough to avoid single-frame flicker.
        var releaseTime: Float = 0.090
        var sampleRate: Float = 48_000
        /// Log-spaced band edges (WPE-style), low → high frequency. Linear
        /// grouping packed all musical energy (≤2 kHz) into the first few of the
        /// 64 bands, so most bars sat flat while Wallpaper Engine's dance across
        /// the whole range — the "full-range motion" is log binning, not noise.
        var lowFrequency: Float = 25
        var highFrequency: Float = 16_000
        /// Treble EQ compensation: each band is boosted by
        /// `(fCenter / lowFrequency)^eqExponent` so upper bands visually keep up
        /// with bass-heavy program material, approximating WPE's per-band
        /// equalization. 0 disables the boost.
        var eqExponent: Float = 0.30
    }

    /// Precomputed FFT-magnitude range + EQ boost for one output band.
    private struct Band {
        let range: Range<Int>
        let boost: Float
    }

    private let configuration: Configuration
    private let fftSetup: vDSP.FFT<DSPSplitComplex>?

    /// Smoothing coefficients depend on the per-callback hop size, which is only
    /// known at `process(...)` time, so they are recomputed when it changes.
    private var attackCoefficient: Float = 1
    private var releaseCoefficient: Float = 1
    private var lastHopSize: Int = 0

    private var window: [Float]
    /// `1 / Σ window`. vDSP's real FFT leaves magnitudes unnormalized (they grow
    /// ~with the transform size and window energy), which made every bin saturate
    /// to 1.0 on real full-scale audio. Scaling magnitudes by this factor brings
    /// them back to amplitude-like units so the dB window + `noiseFloor` below are
    /// calibrated against ~0…1 levels, not raw FFT magnitudes.
    private let inverseWindowSum: Float
    private var leftInput: [Float]
    private var rightInput: [Float]
    private var windowedInput: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var magnitudes: [Float]
    private var compressedBins: [Float]
    private var leftOutput: [Float]
    private var rightOutput: [Float]
    private var previousLeft: [Float]
    private var previousRight: [Float]
    private let bands: [Band]

    init(configuration: Configuration = Configuration()) {
        var resolved = configuration
        if resolved.fftSize < 2 || !Self.isPowerOfTwo(resolved.fftSize) {
            resolved.fftSize = 2048
        }
        resolved.binCount = AudioSpectrumFrame.binCount
        if resolved.maxDB <= resolved.minDB {
            resolved.maxDB = resolved.minDB + 1
        }
        if resolved.sampleRate <= 0 {
            resolved.sampleRate = 48_000
        }

        self.configuration = resolved
        let log2n = vDSP_Length(log2(Double(resolved.fftSize)))
        self.fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)

        var hann = [Float](repeating: 0, count: resolved.fftSize)
        vDSP_hann_window(&hann, vDSP_Length(resolved.fftSize), Int32(vDSP_HANN_NORM))
        self.window = hann
        self.inverseWindowSum = 1 / max(hann.reduce(0, +), 1)
        self.leftInput = [Float](repeating: 0, count: resolved.fftSize)
        self.rightInput = [Float](repeating: 0, count: resolved.fftSize)
        self.windowedInput = [Float](repeating: 0, count: resolved.fftSize)
        self.realBuffer = [Float](repeating: 0, count: resolved.fftSize / 2)
        self.imagBuffer = [Float](repeating: 0, count: resolved.fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: resolved.fftSize / 2)
        self.compressedBins = [Float](repeating: 0, count: resolved.binCount)
        self.leftOutput = [Float](repeating: 0, count: resolved.binCount)
        self.rightOutput = [Float](repeating: 0, count: resolved.binCount)
        self.previousLeft = [Float](repeating: 0, count: resolved.binCount)
        self.previousRight = [Float](repeating: 0, count: resolved.binCount)
        self.bands = Self.logBands(configuration: resolved)
    }

    /// Log-spaced [lowFrequency, highFrequency] band ranges over the FFT
    /// magnitude bins, with the per-band treble EQ boost baked in. Every band
    /// spans at least one FFT bin; edges clamp to the magnitude buffer so a
    /// misconfigured range can't index out of bounds.
    private static func logBands(configuration: Configuration) -> [Band] {
        let halfBins = configuration.fftSize / 2
        let binWidth = configuration.sampleRate / Float(configuration.fftSize)
        let nyquist = configuration.sampleRate * 0.5
        let low = max(min(configuration.lowFrequency, nyquist * 0.5), binWidth)
        let high = max(min(configuration.highFrequency, nyquist * 0.98), low * 2)
        let ratio = high / low
        let count = configuration.binCount

        return (0..<count).map { band in
            let fStart = low * powf(ratio, Float(band) / Float(count))
            let fEnd = low * powf(ratio, Float(band + 1) / Float(count))
            let start = min(max(Int(fStart / binWidth), 1), halfBins - 1)
            let end = min(max(Int((fEnd / binWidth).rounded()), start + 1), halfBins)
            let center = sqrtf(fStart * fEnd)
            let boost = configuration.eqExponent == 0
                ? Float(1)
                : min(powf(center / low, configuration.eqExponent), 16)
            return Band(range: start..<end, boost: boost)
        }
    }

    func process(left: [Float], right: [Float], timestampNanos: UInt64) -> AudioSpectrumFrame {
        updateSmoothingIfNeeded(hopSize: max(left.count, right.count))

        appendSamples(left, into: &leftInput)
        appendSamples(right, into: &rightInput)

        processChannel(input: leftInput, previous: &previousLeft, output: &leftOutput)
        processChannel(input: rightInput, previous: &previousRight, output: &rightOutput)

        return AudioSpectrumFrame(
            validatedLeft: leftOutput,
            validatedRight: rightOutput,
            timestampNanos: timestampNanos
        )
    }

    /// Used by the scene-owned audio fallback when system capture is unavailable.
    func process(mono: [Float], timestampNanos: UInt64) -> AudioSpectrumFrame {
        process(left: mono, right: mono, timestampNanos: timestampNanos)
    }

    // Capture sources convert their AudioBufferList into noninterleaved Float
    // channels at the capture boundary because Core Audio Tap and
    // ScreenCaptureKit expose different buffer layouts and format metadata.

    private func updateSmoothingIfNeeded(hopSize: Int) {
        let hop = hopSize > 0 ? hopSize : configuration.fftSize
        guard hop != lastHopSize else { return }
        lastHopSize = hop
        attackCoefficient = Self.smoothingCoefficient(
            time: configuration.attackTime,
            stepSize: hop,
            sampleRate: configuration.sampleRate
        )
        releaseCoefficient = Self.smoothingCoefficient(
            time: configuration.releaseTime,
            stepSize: hop,
            sampleRate: configuration.sampleRate
        )
    }

    /// Slides the window left by the new sample count and appends fresh samples
    /// at the tail, keeping a continuous `fftSize` history across callbacks.
    private func appendSamples(_ samples: [Float], into target: inout [Float]) {
        let capacity = target.count
        let incoming = min(samples.count, capacity)
        guard incoming > 0 else { return }

        let retained = capacity - incoming
        if retained > 0 {
            target.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                memmove(base, base + incoming, retained * MemoryLayout<Float>.stride)
            }
        }

        // Only the last `incoming` samples of `samples` survive when it is larger
        // than the window; align to its tail so the most recent audio is kept.
        let sourceStart = samples.count - incoming
        for offset in 0..<incoming {
            let sample = samples[sourceStart + offset]
            target[retained + offset] = sample.isFinite ? sample : 0
        }
    }

    private func processChannel(input: [Float], previous: inout [Float], output: inout [Float]) {
        guard let fftSetup else {
            for index in output.indices { output[index] = 0 }
            copyInPlace(output, into: &previous)
            return
        }

        vDSP.multiply(input, window, result: &windowedInput)

        windowedInput.withUnsafeBufferPointer { inputPointer in
            inputPointer.baseAddress!.withMemoryRebound(
                to: DSPComplex.self,
                capacity: configuration.fftSize / 2
            ) { complexPointer in
                realBuffer.withUnsafeMutableBufferPointer { realPointer in
                    imagBuffer.withUnsafeMutableBufferPointer { imagPointer in
                        var split = DSPSplitComplex(
                            realp: realPointer.baseAddress!,
                            imagp: imagPointer.baseAddress!
                        )
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(configuration.fftSize / 2))
                        fftSetup.forward(input: split, output: &split)
                        vDSP.absolute(split, result: &magnitudes)
                    }
                }
            }
        }

        // Normalize the raw FFT magnitudes to amplitude-like units before the
        // dB/noiseFloor mapping (see `inverseWindowSum`).
        vDSP.multiply(inverseWindowSum, magnitudes, result: &magnitudes)

        compressMagnitudesIntoBins()
        normalizeAndSmooth(previous: &previous, output: &output)
    }

    private func compressMagnitudesIntoBins() {
        for (bin, band) in bands.enumerated() {
            var sum: Float = 0
            for index in band.range {
                sum += magnitudes[index]
            }
            compressedBins[bin] = band.boost * sum / Float(band.range.count)
        }
    }

    private func normalizeAndSmooth(previous: inout [Float], output: inout [Float]) {
        let dbRange = configuration.maxDB - configuration.minDB

        for index in 0..<configuration.binCount {
            let mean = compressedBins[index]
            let target: Float
            if mean <= configuration.noiseFloor || !mean.isFinite {
                target = 0
            } else {
                let magnitude = max(mean * configuration.gain, configuration.noiseFloor)
                let db = 20 * log10f(magnitude)
                target = min(max((db - configuration.minDB) / dbRange, 0), 1)
            }

            let coefficient = target > previous[index] ? attackCoefficient : releaseCoefficient
            let smoothed = previous[index] + coefficient * (target - previous[index])
            output[index] = min(max(smoothed, 0), 1)
        }

        copyInPlace(output, into: &previous)
    }

    /// Element-wise copy so `previous` keeps its own backing store. A plain
    /// `previous = output` would alias the output buffer and force a
    /// copy-on-write allocation on the next frame's mutation.
    private func copyInPlace(_ source: [Float], into destination: inout [Float]) {
        let count = min(source.count, destination.count)
        for index in 0..<count {
            destination[index] = source[index]
        }
    }

    private static func smoothingCoefficient(time: Float, stepSize: Int, sampleRate: Float) -> Float {
        guard time > 0, sampleRate > 0, stepSize > 0 else { return 1 }
        let duration = Float(stepSize) / sampleRate
        return min(max(1 - expf(-duration / time), 0), 1)
    }

    private static func isPowerOfTwo(_ value: Int) -> Bool {
        value > 0 && (value & (value - 1)) == 0
    }
}
