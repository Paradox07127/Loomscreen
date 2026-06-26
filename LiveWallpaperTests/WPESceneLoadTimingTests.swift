import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPE scene load timing")
struct WPESceneLoadTimingTests {
    private func t(_ msFromZero: Double) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: UInt64(msFromZero * 1_000_000))
    }

    @Test("Summary pairs X/X.done, sorts phases descending, totals the window")
    func summarizesPhases() throws {
        let marks: [(stage: String, time: DispatchTime)] = [
            ("load.begin", t(0)),
            ("read.entry", t(0)),
            ("read.entry.done", t(10)),
            ("graph.build", t(10)),
            ("graph.build.done", t(40)),
            ("pipeline.build", t(40)),
            ("pipeline.pass", t(50)),   // sub-event with no `.done`: excluded from summary
            ("pipeline.pass", t(60)),
            ("pipeline.build.done", t(440)),
            ("render.firstFrame", t(440)),
            ("render.firstFrame.done", t(500)),
        ]
        let summary = try #require(WPESceneLoadTiming.summarize(workshopID: "123", marks: marks))

        #expect(summary.contains("scene=123"))
        #expect(summary.contains("total=500.0ms"))
        #expect(summary.contains("pipeline.build=400.0ms"))
        #expect(summary.contains("graph.build=30.0ms"))
        #expect(summary.contains("read.entry=10.0ms"))
        #expect(summary.contains("render.firstFrame=60.0ms"))
        #expect(!summary.contains("pipeline.pass"))

        // Phases are sorted by descending cost: pipeline.build (400) precedes render.firstFrame (60).
        let pipeline = try #require(summary.range(of: "pipeline.build="))
        let firstFrame = try #require(summary.range(of: "render.firstFrame="))
        #expect(pipeline.lowerBound < firstFrame.lowerBound)
    }

    @Test("Returns nil with fewer than two marks")
    func nilWhenInsufficientMarks() {
        #expect(WPESceneLoadTiming.summarize(workshopID: "x", marks: []) == nil)
        #expect(WPESceneLoadTiming.summarize(workshopID: "x", marks: [("load.begin", t(0))]) == nil)
    }
}
