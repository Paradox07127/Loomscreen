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

    @Test("cpuText: whole number ≥10, one decimal under 10, clamped at 0.0")
    func cpuTextFormat() {
        #expect(MonitorProcessesWidgetView.cpuText(52) == "52")
        #expect(MonitorProcessesWidgetView.cpuText(23.4) == "23")
        #expect(MonitorProcessesWidgetView.cpuText(23.6) == "24")
        #expect(MonitorProcessesWidgetView.cpuText(0.44) == "0.4")
        #expect(MonitorProcessesWidgetView.cpuText(3.24) == "3.2")
        // Tenths-first rounding: 9.97 → 10.0 tenths → crosses into the
        // integer branch, so no trailing ".0".
        #expect(MonitorProcessesWidgetView.cpuText(9.97) == "10")
        #expect(MonitorProcessesWidgetView.cpuText(-3) == "0.0")
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

    // MARK: - Physical row capacity at the fixed Apple frames

    @Test("capacity at the exact Apple frames: M 170pt fits 7 rows, L 376pt fits 19")
    func rowCapacityAtAppleFrames() {
        #expect(MonitorProcessesWidgetView.rowCapacity(frameHeight: 170, scaleHeight: 85) == 7)
        #expect(MonitorProcessesWidgetView.rowCapacity(frameHeight: 376, scaleHeight: 94) == 19)
    }

    @Test("degenerate height yields zero capacity (the view floors displayed rows at 1)")
    func rowCapacityDegenerate() {
        #expect(MonitorProcessesWidgetView.rowCapacity(frameHeight: 40, scaleHeight: 85) == 0)
    }

    @Test("capacity grows monotonically with frame height")
    func rowCapacityMonotonic() {
        let short = MonitorProcessesWidgetView.rowCapacity(frameHeight: 190, scaleHeight: 94)
        let tall = MonitorProcessesWidgetView.rowCapacity(frameHeight: 376, scaleHeight: 94)
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
