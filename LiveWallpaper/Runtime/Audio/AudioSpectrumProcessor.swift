import Accelerate
import Foundation

/// Reusable stereo FFT → 64-bin spectrum processor. Buffers are preallocated and
/// reused so steady-state processing performs no heap allocation, allowing it to
/// run directly on a Core Audio IOProc or ScreenCaptureKit sample queue.
///
/// Channels are kept separate (no mono collapse) and each bin is dB-normalized
/// with attack/release temporal smoothing so the visual response matches
/// Wallpaper Engine instead of jumping on raw magnitudes.
///
/// Incoming callback buffers are usually smaller than `fftSize` (devices deliver
/// 256–1024 frames). The input buffers act as a sliding window: each call shifts
/// history left and appends the new samples at the tail, so the FFT always sees a
/// full window instead of a zero-padded fragment.
final class AudioSpectrumProcessor {
    struct Configuration: Equatable, Sendable {
        var fftSize: Int = 2048
        var binCount: Int = 64
        var minDB: Float = -80
        var maxDB: Float = -12
        var gain: Float = 1.15
        var noiseFloor: Float = 0.002
        var attackTime: Float = 0.045
        var releaseTime: Float = 0.180
        var sampleRate: Float = 48_000
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
        let inputBins = magnitudes.count
        let groupSize = max(1, inputBins / configuration.binCount)

        for bin in 0..<configuration.binCount {
            let start = bin * groupSize
            let end = min(start + groupSize, inputBins)
            guard start < end else {
                compressedBins[bin] = 0
                continue
            }

            var sum: Float = 0
            for index in start..<end {
                sum += magnitudes[index]
            }
            compressedBins[bin] = sum / Float(end - start)
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
