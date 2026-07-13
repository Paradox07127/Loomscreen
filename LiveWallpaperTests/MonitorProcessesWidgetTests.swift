import Testing
import Foundation
@testable import LiveWallpaper

/// Pure-logic tests for the Processes widget: row ordering + capping, the
/// integer cpu% readout (no percent sign, rounded), and CPU-bar normalization
/// to the busiest shown row. View composition is not exercised here.
struct MonitorProcessesWidgetTests {

    private func proc(_ name: String, _ cpu: Double, _ mem: UInt64 = 0) -> MonitorProcessSample {
        MonitorProcessSample(name: name, cpuPercent: cpu, memBytes: mem)
    }

    // MARK: - topProcesses ordering + capping

    @Test("nil / empty input yields no rows")
    func emptyInput() {
        #expect(MonitorProcessesWidgetView.topProcesses(nil, limit: 5).isEmpty)
        #expect(MonitorProcessesWidgetView.topProcesses([], limit: 5).isEmpty)
    }

    @Test("rows are re-sorted by cpu% descending and capped to the limit")
    func sortsAndCaps() {
        let input = [proc("a", 7), proc("b", 52), proc("c", 23), proc("d", 31), proc("e", 18), proc("f", 9)]
        let rows = MonitorProcessesWidgetView.topProcesses(input, limit: 5)
        #expect(rows.count == 5)
        #expect(rows.map(\.cpuPercent) == [52, 31, 23, 18, 9])
        #expect(rows.first?.name == "b")
    }

    @Test("ties preserve the sampler's original order (stable)")
    func stableOnTies() {
        let input = [proc("first23", 23), proc("hi", 52), proc("second23", 23)]
        let rows = MonitorProcessesWidgetView.topProcesses(input, limit: 5)
        #expect(rows.map(\.name) == ["hi", "first23", "second23"])
    }

    @Test("a limit larger than the list returns every row")
    func limitBeyondCount() {
        let rows = MonitorProcessesWidgetView.topProcesses([proc("a", 5), proc("b", 9)], limit: 5)
        #expect(rows.count == 2)
    }

    // MARK: - cpu% readout

    @Test("cpuText is a whole number with no percent sign, rounded")
    func cpuTextFormat() {
        #expect(MonitorProcessesWidgetView.cpuText(52) == "52")
        #expect(MonitorProcessesWidgetView.cpuText(23.4) == "23")
        #expect(MonitorProcessesWidgetView.cpuText(23.6) == "24")
        #expect(MonitorProcessesWidgetView.cpuText(-3) == "0")
    }

    // MARK: - bar normalization

    @Test("bar fraction normalizes to the busiest row, clamped 0…1")
    func barNormalizesToMax() {
        // Busiest row is full; a half-CPU row is half length.
        #expect(MonitorProcessesWidgetView.barFraction(52, maxCPU: 52) == 1)
        #expect(abs(MonitorProcessesWidgetView.barFraction(26, maxCPU: 52) - 0.5) < 1e-9)
        // Guard: a zero/degenerate max never divides by zero.
        #expect(MonitorProcessesWidgetView.barFraction(0, maxCPU: 0) == 0)
    }

    // MARK: - L's height-driven auto row count

    @Test("auto row limit fits more rows at L's real (2× M) height, capped at the stepper's 8")
    func autoLargeRowLimitAtRealHeight() {
        // L's rendered height on the 14" 1512×982pt board (SPEC runtime contract):
        // raw 392pt − ~14pt tileInset ≈ 379pt. Far more than 8 rows physically
        // fit, so this lands on the settings stepper's ceiling.
        #expect(MonitorProcessesWidgetView.autoLargeRowLimit(cellHeight: 379) == 8)
    }

    @Test("auto row limit is a genuine mid-range fit, not just the floor or the cap")
    func autoLargeRowLimitMidRange() {
        #expect(MonitorProcessesWidgetView.autoLargeRowLimit(cellHeight: 190) == 6)
    }

    @Test("auto row limit never drops below M's fixed default of 5")
    func autoLargeRowLimitFloors() {
        // A degenerate/tiny height (available space goes negative once chrome
        // is subtracted) still shows at least as many rows as M's fixed default.
        #expect(MonitorProcessesWidgetView.autoLargeRowLimit(cellHeight: 40) == 5)
    }

    @Test("auto row limit grows monotonically with height")
    func autoLargeRowLimitMonotonic() {
        let short = MonitorProcessesWidgetView.autoLargeRowLimit(cellHeight: 190)
        let tall = MonitorProcessesWidgetView.autoLargeRowLimit(cellHeight: 379)
        #expect(short <= tall)
    }

    // MARK: - Header text-vs-icon contingency

    @Test("header keeps the CPU/MEM acronym when the column is wide enough")
    func headerFitsTextWhenWide() {
        // The board's actual column width (`--cpucol`/MEM = 3.4em of the caption
        // base) at both M and L's clamped label/caption sizes.
        #expect(MonitorProcessesWidgetView.headerFitsText(columnWidth: 44, labelSize: 12))
        // Still fits at the smallest clamp the type scale ever produces.
        #expect(MonitorProcessesWidgetView.headerFitsText(columnWidth: 34, labelSize: 9))
    }

    @Test("header falls back to an SF Symbol when the column is too narrow")
    func headerFallsBackToIconWhenNarrow() {
        #expect(!MonitorProcessesWidgetView.headerFitsText(columnWidth: 10, labelSize: 12))
        #expect(!MonitorProcessesWidgetView.headerFitsText(columnWidth: 15, labelSize: 12))
    }
}
