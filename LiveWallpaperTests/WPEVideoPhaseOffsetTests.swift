import Foundation
import Testing
@testable import LiveWallpaper

/// Cross-correlation core for the intro→loop seamless handoff. `bestLag` must
/// recover the phase shift between an intro overlay and the loop it reveals
/// (scene 3632513108: `intro@t ≈ loop@(t+2)`), and decline when the two videos
/// are unrelated content (flat correlation).
@Suite("WPE intro→loop phase offset")
struct WPEVideoPhaseOffsetTests {
    /// One grayscale "frame" per grid time: a distinct ramp value so each loop
    /// time has a recognizable signature.
    private func rampFrames(duration: Double, step: Double) -> (times: [Double], frames: [[Float]]) {
        let times = Array(stride(from: 0.0, to: duration, by: step))
        let frames = times.map { [Float($0.truncatingRemainder(dividingBy: duration))] }
        return (times, frames)
    }

    @Test("recovers a known +2s phase shift")
    func recoversKnownShift() {
        let duration = 12.0, step = 0.5, shift = 2.0
        let loop = rampFrames(duration: duration, step: step)
        let introTimes = Array(stride(from: 1.0, through: 9.0, by: 2.0))
        let introFrames = introTimes.map {
            [Float(($0 + shift).truncatingRemainder(dividingBy: duration))]
        }
        let lag = WPEVideoPhaseOffset.bestLag(
            introTimes: introTimes, introFrames: introFrames,
            loopFrames: loop.frames, loopStep: step, loopDuration: duration
        )
        #expect(lag != nil)
        #expect(abs((lag ?? -99) - shift) <= 0.25)
    }

    @Test("declines when content is unrelated (flat correlation)")
    func declinesUnrelated() {
        let duration = 12.0, step = 0.5
        let loop = rampFrames(duration: duration, step: step)
        // Intro frames all identical → every lag scores the same → no winner.
        let introTimes = Array(stride(from: 1.0, through: 9.0, by: 2.0))
        let introFrames = introTimes.map { _ in [Float(123)] }
        let lag = WPEVideoPhaseOffset.bestLag(
            introTimes: introTimes, introFrames: introFrames,
            loopFrames: loop.frames, loopStep: step, loopDuration: duration
        )
        #expect(lag == nil)
    }

    @Test("recovers a zero shift (already aligned)")
    func recoversZeroShift() {
        let duration = 12.0, step = 0.5
        let loop = rampFrames(duration: duration, step: step)
        let introTimes = Array(stride(from: 1.0, through: 9.0, by: 2.0))
        let introFrames = introTimes.map { [Float($0.truncatingRemainder(dividingBy: duration))] }
        let lag = WPEVideoPhaseOffset.bestLag(
            introTimes: introTimes, introFrames: introFrames,
            loopFrames: loop.frames, loopStep: step, loopDuration: duration
        )
        #expect(lag != nil)
        #expect(abs(lag ?? -99) <= 0.25)
    }
}
