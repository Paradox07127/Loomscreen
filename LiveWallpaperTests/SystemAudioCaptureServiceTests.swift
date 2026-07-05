#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

/// Unit coverage for the pure channel-extraction seam of
/// `SystemAudioCaptureService`. The Core Audio tap lifecycle itself needs real
/// hardware; the deinterleave math does not.
@Suite("System audio capture — channel extraction")
struct SystemAudioCaptureServiceTests {
    @available(macOS 14.2, *)
    private func runInterleaved(_ source: [Float], channelCount: Int, frameCount: Int) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: -1, count: frameCount)
        var right = [Float](repeating: -1, count: frameCount)
        source.withUnsafeBufferPointer { src in
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    guard let srcBase = src.baseAddress,
                          let leftBase = l.baseAddress,
                          let rightBase = r.baseAddress else {
                        fatalError("Failed to unwrap interleaved base addresses")
                    }
                    SystemAudioCaptureService.writeInterleavedStereo(
                        srcBase,
                        channelCount: channelCount,
                        frameCount: frameCount,
                        left: leftBase,
                        right: rightBase
                    )
                }
            }
        }
        return (left, right)
    }

    @available(macOS 14.2, *)
    @Test("Interleaved stereo splits L/R by stride")
    func interleavedStereoSplits() {
        // [l0, r0, l1, r1, l2, r2]
        let source: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        let (left, right) = runInterleaved(source, channelCount: 2, frameCount: 3)
        #expect(left == [0.1, 0.3, 0.5])
        #expect(right == [0.2, 0.4, 0.6])
    }

    @available(macOS 14.2, *)
    @Test("Interleaved multichannel takes channels 0 and 1")
    func interleavedMultichannelTakesFirstTwo() {
        // 6-channel frames: [c0..c5] per frame.
        let frame0: [Float] = [1, 2, 3, 4, 5, 6]
        let frame1: [Float] = [7, 8, 9, 10, 11, 12]
        let (left, right) = runInterleaved(frame0 + frame1, channelCount: 6, frameCount: 2)
        #expect(left == [1, 7])
        #expect(right == [2, 8])
    }

    @available(macOS 14.2, *)
    @Test("Interleaved mono duplicates into both channels")
    func interleavedMonoDuplicates() {
        let source: [Float] = [0.25, 0.5, 0.75]
        let (left, right) = runInterleaved(source, channelCount: 1, frameCount: 3)
        #expect(left == [0.25, 0.5, 0.75])
        #expect(right == left)
    }

    @available(macOS 14.2, *)
    @Test("Planar stereo copies both channels")
    func planarStereoCopies() {
        let leftSource: [Float] = [0.1, 0.2, 0.3]
        let rightSource: [Float] = [0.4, 0.5, 0.6]
        var left = [Float](repeating: -1, count: 3)
        var right = [Float](repeating: -1, count: 3)
        leftSource.withUnsafeBufferPointer { l0 in
            rightSource.withUnsafeBufferPointer { r0 in
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        guard let l0Base = l0.baseAddress,
                              let r0Base = r0.baseAddress,
                              let lBase = l.baseAddress,
                              let rBase = r.baseAddress else {
                            Issue.record("Failed to unwrap planar base addresses")
                            return
                        }
                        SystemAudioCaptureService.writePlanarStereo(
                            left: l0Base,
                            right: r0Base,
                            frameCount: 3,
                            left: lBase,
                            right: rBase
                        )
                    }
                }
            }
        }
        #expect(left == [0.1, 0.2, 0.3])
        #expect(right == [0.4, 0.5, 0.6])
    }

    @available(macOS 14.2, *)
    @Test("Planar mono (missing right) duplicates left")
    func planarMonoDuplicates() {
        let leftSource: [Float] = [0.1, 0.2, 0.3]
        var left = [Float](repeating: -1, count: 3)
        var right = [Float](repeating: -1, count: 3)
        leftSource.withUnsafeBufferPointer { l0 in
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    guard let l0Base = l0.baseAddress,
                          let lBase = l.baseAddress,
                          let rBase = r.baseAddress else {
                        Issue.record("Failed to unwrap planar base addresses")
                        return
                    }
                    SystemAudioCaptureService.writePlanarStereo(
                        left: l0Base,
                        right: nil,
                        frameCount: 3,
                        left: lBase,
                        right: rBase
                    )
                }
            }
        }
        #expect(left == [0.1, 0.2, 0.3])
        #expect(right == [0.1, 0.2, 0.3])
    }
}
#endif
