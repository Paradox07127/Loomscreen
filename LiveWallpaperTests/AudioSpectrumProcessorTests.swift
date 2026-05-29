import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Audio spectrum processor")
struct AudioSpectrumProcessorTests {
    @Test("Silence produces all-zero stereo bins")
    func silenceProducesAllZeroStereoBins() {
        let processor = AudioSpectrumProcessor()
        let samples = [Float](repeating: 0, count: 2048)

        let frame = processor.process(left: samples, right: samples, timestampNanos: 1)

        #expect(frame.left.count == AudioSpectrumFrame.binCount)
        #expect(frame.right.count == AudioSpectrumFrame.binCount)
        #expect(frame.left.allSatisfy { $0 == 0 })
        #expect(frame.right.allSatisfy { $0 == 0 })
    }

    @Test("Mono helper duplicates left and right channels")
    func monoHelperDuplicatesLeftAndRightChannels() {
        let processor = AudioSpectrumProcessor()
        let samples = Self.sineWave(cycles: 8, amplitude: 0.8)

        let frame = processor.process(mono: samples, timestampNanos: 2)

        #expect(frame.left == frame.right)
        #expect(frame.left.contains { $0 > 0 })
    }

    @Test("Distinct stereo input preserves different left and right spectra")
    func distinctStereoInputPreservesDifferentChannels() {
        let processor = AudioSpectrumProcessor()
        let left = Self.sineWave(cycles: 6, amplitude: 0.8)
        let right = Self.sineWave(cycles: 96, amplitude: 0.8)

        let frame = processor.process(left: left, right: right, timestampNanos: 3)

        #expect(frame.left != frame.right)
        #expect(Self.peakIndex(frame.left) != Self.peakIndex(frame.right))
    }

    @Test("Attack rises faster than release falls")
    func attackRisesFasterThanReleaseFalls() {
        let processor = AudioSpectrumProcessor()
        let loud = Self.sineWave(cycles: 12, amplitude: 1.0)
        let silence = [Float](repeating: 0, count: 2048)

        let attackFrame = processor.process(left: loud, right: loud, timestampNanos: 4)
        let releaseFrame = processor.process(left: silence, right: silence, timestampNanos: 5)

        let attackPeak = attackFrame.left.max() ?? 0
        let releasePeak = releaseFrame.left.max() ?? 0
        let releaseDrop = attackPeak - releasePeak

        #expect(attackPeak > 0)
        #expect(releasePeak > 0)
        #expect(attackPeak > releaseDrop)
    }

    @Test("Normalization stays inside zero one range")
    func normalizationStaysInsideZeroOneRange() {
        let processor = AudioSpectrumProcessor()
        let left = Self.sineWave(cycles: 16, amplitude: 50)
        let right = Self.sineWave(cycles: 24, amplitude: 50)

        let frame = processor.process(left: left, right: right, timestampNanos: 6)

        #expect(Self.isNormalized(frame.left))
        #expect(Self.isNormalized(frame.right))
    }

    @Test("Short and empty buffers are handled without crashing")
    func shortAndEmptyBuffersAreHandledWithoutCrashing() {
        let processor = AudioSpectrumProcessor()

        let empty = processor.process(left: [], right: [], timestampNanos: 7)
        let short = processor.process(left: [0.25, -0.25, .nan], right: [0.5], timestampNanos: 8)

        #expect(empty.left.count == AudioSpectrumFrame.binCount)
        #expect(empty.right.count == AudioSpectrumFrame.binCount)
        #expect(short.left.count == AudioSpectrumFrame.binCount)
        #expect(short.right.count == AudioSpectrumFrame.binCount)
        #expect(Self.isNormalized(empty.left))
        #expect(Self.isNormalized(empty.right))
        #expect(Self.isNormalized(short.left))
        #expect(Self.isNormalized(short.right))
    }

    @Test("Sliding window retains history across smaller-than-FFT callbacks")
    func slidingWindowRetainsHistoryAcrossSmallCallbacks() {
        let processor = AudioSpectrumProcessor()

        // Two 1024-sample callbacks (smaller than the 2048 FFT window): silence
        // then signal. With a sliding window the second frame's FFT sees a full
        // window (old silence + new signal) rather than a zero-padded fragment.
        let silence = [Float](repeating: 0, count: 1024)
        _ = processor.process(left: silence, right: silence, timestampNanos: 10)

        let active = Self.sineWave(cycles: 10, amplitude: 0.8, count: 1024)
        let frame = processor.process(left: active, right: active, timestampNanos: 11)

        #expect(frame.left.contains { $0 > 0 })
        #expect(Self.isNormalized(frame.left))
    }

    private static func sineWave(cycles: Float, amplitude: Float, count: Int = 2048) -> [Float] {
        (0..<count).map { index in
            amplitude * sinf(2 * Float.pi * cycles * Float(index) / Float(count))
        }
    }

    private static func peakIndex(_ values: [Float]) -> Int {
        values.enumerated().max { lhs, rhs in lhs.element < rhs.element }?.offset ?? -1
    }

    private static func isNormalized(_ values: [Float]) -> Bool {
        values.allSatisfy { value in
            value.isFinite && value >= 0 && value <= 1
        }
    }
}
