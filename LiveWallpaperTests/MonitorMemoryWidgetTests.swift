import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

final class MonitorMemoryWidgetTests: XCTestCase {

    private let g = 1_073_741_824.0

    func testPressureMapping() {
        XCTAssertEqual(MonitorMemoryWidgetView.pressure("normal"), .normal)
        XCTAssertEqual(MonitorMemoryWidgetView.pressure(nil), .normal)
        XCTAssertEqual(MonitorMemoryWidgetView.pressure("warn"), .warn)
        XCTAssertEqual(MonitorMemoryWidgetView.pressure("warning"), .warn)
        XCTAssertEqual(MonitorMemoryWidgetView.pressure("critical"), .critical)
        XCTAssertEqual(MonitorMemoryWidgetView.pressure("crit"), .critical)
        XCTAssertEqual(MonitorMemoryWidgetView.pressure("bogus"), .normal)
    }

    func testPressureLevelForCurve() {
        XCTAssertEqual(MonitorMemoryWidgetView.pressureLevel("normal"), 0)
        XCTAssertEqual(MonitorMemoryWidgetView.pressureLevel("warn"), 1)
        XCTAssertEqual(MonitorMemoryWidgetView.pressureLevel("critical"), 2)
    }

    func testSwapHiddenWhenZeroAndNormal() {
        XCTAssertFalse(MonitorMemoryWidgetView.showsSwap(swapBytes: 0, pressure: "normal"))
        XCTAssertFalse(MonitorMemoryWidgetView.showsSwap(swapBytes: nil, pressure: "normal"))
    }

    func testSwapShownWhenNonZero() {
        XCTAssertTrue(MonitorMemoryWidgetView.showsSwap(swapBytes: 1, pressure: "normal"))
        XCTAssertTrue(MonitorMemoryWidgetView.showsSwap(swapBytes: UInt64(2.4 * g), pressure: "normal"))
    }

    func testSwapShownWhenPressureRaisedEvenWithZeroSwap() {
        XCTAssertTrue(MonitorMemoryWidgetView.showsSwap(swapBytes: 0, pressure: "warn"))
        XCTAssertTrue(MonitorMemoryWidgetView.showsSwap(swapBytes: nil, pressure: "critical"))
    }

    func testSegmentsOrderLabelsAndFractions() {
        let breakdown = MonitorMemoryBreakdown(
            appBytes: UInt64(8.9 * g),
            wiredBytes: UInt64(4.2 * g),
            compressedBytes: UInt64(2.0 * g),
            cachedFilesBytes: UInt64(6.4 * g)
        )
        let total = 32 * g
        let segs = MonitorMemoryWidgetView.segments(
            breakdown: breakdown, swap: UInt64(1.1 * g), total: total)

        XCTAssertEqual(segs.map(\.kind),
                       [.app, .wired, .compressed, .cached, .swap])
        XCTAssertEqual(segs.map(\.label),
                       ["App", "Wired", "Compressed", "Cached Files", "Swap"])

        XCTAssertEqual(segs[0].fraction, 8.9 / 32, accuracy: 0.001)
        XCTAssertEqual(segs[1].fraction, 4.2 / 32, accuracy: 0.001)
        XCTAssertEqual(segs[2].fraction, 2.0 / 32, accuracy: 0.001)
        XCTAssertEqual(segs[3].fraction, 6.4 / 32, accuracy: 0.001)
        XCTAssertEqual(segs[4].fraction, 1.1 / 32, accuracy: 0.001)
    }

    func testFreeFractionIgnoresSwap() {
        let breakdown = MonitorMemoryBreakdown(
            appBytes: UInt64(8.9 * g),
            wiredBytes: UInt64(4.2 * g),
            compressedBytes: UInt64(2.0 * g),
            cachedFilesBytes: UInt64(6.4 * g)
        )
        let free = MonitorMemoryWidgetView.freeFraction(breakdown: breakdown, total: 32 * g)
        XCTAssertEqual(free, (32 - 21.5) / 32, accuracy: 0.001)
    }

    func testFractionsClampAndTotalGuard() {
        let breakdown = MonitorMemoryBreakdown(
            appBytes: UInt64(40 * g), wiredBytes: 0, compressedBytes: 0, cachedFilesBytes: 0)
        let segs = MonitorMemoryWidgetView.segments(breakdown: breakdown, swap: 0, total: 32 * g)
        XCTAssertEqual(segs[0].fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(MonitorMemoryWidgetView.freeFraction(breakdown: breakdown, total: 32 * g), 0)
        let safe = MonitorMemoryWidgetView.segments(breakdown: breakdown, swap: 0, total: 0)
        XCTAssertTrue(safe.allSatisfy { $0.fraction.isFinite })
    }

    func testPressureRunsSingleLevel() {
        let levels = [0, 0, 0, 0]
        let runs = MonitorMemoryWidgetView.pressureRuns(count: levels.count) { levels[$0] }
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].range, 0...3)
        XCTAssertEqual(runs[0].level, 0)
    }

    func testPressureRunsSplitAtLevelChangeWithSharedBoundary() {
        let levels = [0, 0, 0, 1, 1, 0, 0]
        let runs = MonitorMemoryWidgetView.pressureRuns(count: levels.count) { levels[$0] }
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.map(\.level), [0, 1, 0])
        XCTAssertEqual(runs[0].range, 0...3)
        XCTAssertEqual(runs[1].range, 3...5)
        XCTAssertEqual(runs[2].range, 5...6)
    }

    func testPressureRunsEmpty() {
        XCTAssertTrue(MonitorMemoryWidgetView.pressureRuns(count: 0) { _ in 0 }.isEmpty)
    }

    func testPressureRunsEveryRangeInBounds() {
        let levels = [2, 0, 1, 1, 2, 2, 0]
        let n = levels.count
        let runs = MonitorMemoryWidgetView.pressureRuns(count: n) { levels[$0] }
        for run in runs {
            XCTAssertGreaterThanOrEqual(run.range.lowerBound, 0)
            XCTAssertLessThan(run.range.upperBound, n)
        }
        XCTAssertEqual(runs.first?.range.lowerBound, 0)
        XCTAssertEqual(runs.last?.range.upperBound, n - 1)
    }

    func testHistoryWindowSamplesFallsBackWhenOptionAbsent() {
        XCTAssertEqual(MonitorMemoryWidgetView.historyWindowSamples(optionSeconds: nil, fallbackSeconds: 60), 60)
        XCTAssertEqual(MonitorMemoryWidgetView.historyWindowSamples(optionSeconds: nil, fallbackSeconds: 120), 120)
    }

    func testHistoryWindowSamplesHonoursOverride() {
        XCTAssertEqual(MonitorMemoryWidgetView.historyWindowSamples(optionSeconds: 30, fallbackSeconds: 60), 30)
        XCTAssertEqual(MonitorMemoryWidgetView.historyWindowSamples(optionSeconds: 90.6, fallbackSeconds: 120), 91)
    }

    func testHistoryWindowSamplesRejectsInvalidOverrides() {
        XCTAssertEqual(MonitorMemoryWidgetView.historyWindowSamples(optionSeconds: 0, fallbackSeconds: 60), 60)
        XCTAssertEqual(MonitorMemoryWidgetView.historyWindowSamples(optionSeconds: -5, fallbackSeconds: 60), 60)
        XCTAssertEqual(MonitorMemoryWidgetView.historyWindowSamples(optionSeconds: .nan, fallbackSeconds: 60), 60)
        XCTAssertEqual(MonitorMemoryWidgetView.historyWindowSamples(optionSeconds: .infinity, fallbackSeconds: 60), 60)
    }

    func testHistoryWindowSamplesFloorsAtTwo() {
        XCTAssertEqual(MonitorMemoryWidgetView.historyWindowSamples(optionSeconds: 0.4, fallbackSeconds: 60), 2)
    }

    func testShowsTopProcessesDefaultsToTrue() {
        XCTAssertTrue(MonitorMemoryWidgetView.showsTopProcesses(nil))
    }

    func testShowsTopProcessesHonoursExplicitValue() {
        XCTAssertTrue(MonitorMemoryWidgetView.showsTopProcesses(true))
        XCTAssertFalse(MonitorMemoryWidgetView.showsTopProcesses(false))
    }

    func testBreakdownIsCompactOnlyForTheCompactLiteral() {
        XCTAssertFalse(MonitorMemoryWidgetView.breakdownIsCompact(nil))
        XCTAssertFalse(MonitorMemoryWidgetView.breakdownIsCompact("full"))
        XCTAssertFalse(MonitorMemoryWidgetView.breakdownIsCompact("bogus"))
        XCTAssertTrue(MonitorMemoryWidgetView.breakdownIsCompact("compact"))
    }

    func testTopByMemoryRanksDescendingByRSS() {
        let procs = [
            MonitorProcessSample(name: "Safari", cpuPercent: 3, memBytes: UInt64(0.82 * g)),
            MonitorProcessSample(name: "Xcode", cpuPercent: 22, memBytes: UInt64(3.4 * g)),
            MonitorProcessSample(name: "Helper", cpuPercent: 4, memBytes: UInt64(1.4 * g)),
        ]
        let ranked = MonitorMemoryWidgetView.topByMemory(procs, limit: 5)
        XCTAssertEqual(ranked.map(\.name), ["Xcode", "Helper", "Safari"])
    }

    func testTopByMemoryCapsAtLimit() {
        let procs = (0..<10).map {
            MonitorProcessSample(name: "p\($0)", cpuPercent: 0, memBytes: UInt64($0) * 1_000_000)
        }
        let ranked = MonitorMemoryWidgetView.topByMemory(procs, limit: 5)
        XCTAssertEqual(ranked.count, 5)
        XCTAssertEqual(ranked.map(\.name), ["p9", "p8", "p7", "p6", "p5"])
    }

    func testTopByMemoryTiesBreakByOriginalOrder() {
        let procs = [
            MonitorProcessSample(name: "first", cpuPercent: 0, memBytes: 100),
            MonitorProcessSample(name: "second", cpuPercent: 0, memBytes: 100),
        ]
        let ranked = MonitorMemoryWidgetView.topByMemory(procs, limit: 5)
        XCTAssertEqual(ranked.map(\.name), ["first", "second"])
    }

    func testTopByMemoryEmptyOrNilInputYieldsEmptyOutput() {
        XCTAssertTrue(MonitorMemoryWidgetView.topByMemory(nil, limit: 5).isEmpty)
        XCTAssertTrue(MonitorMemoryWidgetView.topByMemory([], limit: 5).isEmpty)
    }

    func testProcessBarFractionScalesToTop() {
        XCTAssertEqual(MonitorMemoryWidgetView.processBarFraction(UInt64(1.7 * g), top: UInt64(3.4 * g)), 0.5, accuracy: 0.001)
        XCTAssertEqual(MonitorMemoryWidgetView.processBarFraction(UInt64(3.4 * g), top: UInt64(3.4 * g)), 1.0, accuracy: 0.001)
    }

    func testProcessBarFractionGuardsZeroTop() {
        XCTAssertEqual(MonitorMemoryWidgetView.processBarFraction(100, top: 0), 0)
    }
}
