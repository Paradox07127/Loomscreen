import Testing
import Foundation
@testable import LiveWallpaper

struct MonitorDiskWidgetTests {

    @Test("tail returns the last N samples, or the whole series when shorter")
    func tailWindow() {
        let series = (0..<30).map(Double.init)
        let last20 = MonitorDiskWidgetView.tail(series, count: 20)
        #expect(last20.count == 20)
        #expect(last20.first == 10)
        #expect(last20.last == 29)

        let short = [1.0, 2.0, 3.0]
        #expect(MonitorDiskWidgetView.tail(short, count: 20) == short)
    }

    @Test("tail also windows the L card's 120-sample default")
    func tailWindowLarge() {
        let series = (0..<200).map(Double.init)
        let last120 = MonitorDiskWidgetView.tail(series, count: 120)
        #expect(last120.count == 120)
        #expect(last120.first == 80)
        #expect(last120.last == 199)

        let atCapacity = (0..<120).map(Double.init)
        #expect(MonitorDiskWidgetView.tail(atCapacity, count: 120) == atCapacity)
    }

    @Test("absent/invalid historyWindow falls back to the caller's default")
    func historyWindowFallsBackWhenAbsent() {
        #expect(MonitorDiskWidgetView.historyWindowSamples(optionSeconds: nil, fallbackSeconds: 120) == 120)
        #expect(MonitorDiskWidgetView.historyWindowSamples(optionSeconds: 0, fallbackSeconds: 120) == 120)
        #expect(MonitorDiskWidgetView.historyWindowSamples(optionSeconds: -30, fallbackSeconds: 120) == 120)
        #expect(MonitorDiskWidgetView.historyWindowSamples(optionSeconds: .nan, fallbackSeconds: 120) == 120)
        #expect(MonitorDiskWidgetView.historyWindowSamples(optionSeconds: .infinity, fallbackSeconds: 120) == 120)
    }

    @Test("a valid historyWindow override rounds to the nearest sample, floored at 2")
    func historyWindowUsesValidOverride() {
        #expect(MonitorDiskWidgetView.historyWindowSamples(optionSeconds: 60, fallbackSeconds: 120) == 60)
        #expect(MonitorDiskWidgetView.historyWindowSamples(optionSeconds: 59.6, fallbackSeconds: 120) == 60)
        #expect(MonitorDiskWidgetView.historyWindowSamples(optionSeconds: 0.4, fallbackSeconds: 120) == 2)
    }

    @Test("only the literal 'compact' collapses the split legend")
    func breakdownCompactOnlyOnLiteral() {
        #expect(MonitorDiskWidgetView.breakdownIsCompact("compact"))
        #expect(MonitorDiskWidgetView.breakdownIsCompact(nil) == false)
        #expect(MonitorDiskWidgetView.breakdownIsCompact("full") == false)
        #expect(MonitorDiskWidgetView.breakdownIsCompact("Compact") == false)
    }

    @Test("split fractions divide read/write bytes proportionally")
    func splitFractionsNormal() {
        let split = MonitorDiskWidgetView.splitFractions(readBytes: 3, writeBytes: 1)
        #expect(split.read == 0.75)
        #expect(split.write == 0.25)
    }

    @Test("a zero total yields zero fractions, never a division by zero")
    func splitFractionsZeroTotal() {
        let split = MonitorDiskWidgetView.splitFractions(readBytes: 0, writeBytes: 0)
        #expect(split.read == 0)
        #expect(split.write == 0)
    }

    @Test("negative/non-finite inputs clamp to zero before dividing")
    func splitFractionsClampsInputs() {
        let split = MonitorDiskWidgetView.splitFractions(readBytes: -5, writeBytes: 10)
        #expect(split.read == 0)
        #expect(split.write == 1)

        let nanSplit = MonitorDiskWidgetView.splitFractions(readBytes: .nan, writeBytes: 4)
        #expect(nanSplit.read == 0)
        #expect(nanSplit.write == 1)
    }
}
