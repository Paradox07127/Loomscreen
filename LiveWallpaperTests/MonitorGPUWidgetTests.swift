import Testing
import Foundation
@testable import LiveWallpaper

struct MonitorGPUWidgetTests {

    @Test("a supported historyWindow value (30/60/120) passes through unchanged")
    func historyWindowSupportedValues() {
        #expect(MonitorGPUWidgetView.resolvedHistoryWindowSeconds(30) == 30)
        #expect(MonitorGPUWidgetView.resolvedHistoryWindowSeconds(60) == 60)
        #expect(MonitorGPUWidgetView.resolvedHistoryWindowSeconds(120) == 120)
    }

    @Test("a missing historyWindow option defaults to 60s")
    func historyWindowDefaultsWhenNil() {
        #expect(MonitorGPUWidgetView.resolvedHistoryWindowSeconds(nil) == 60)
    }

    @Test("an off-catalog historyWindow value falls back to 60s rather than a bogus window")
    func historyWindowFallsBackWhenOffCatalog() {
        #expect(MonitorGPUWidgetView.resolvedHistoryWindowSeconds(45) == 60)
        #expect(MonitorGPUWidgetView.resolvedHistoryWindowSeconds(0) == 60)
        #expect(MonitorGPUWidgetView.resolvedHistoryWindowSeconds(-30) == 60)
        #expect(MonitorGPUWidgetView.resolvedHistoryWindowSeconds(9999) == 60)
    }

    @Test("compute gap is Device − Renderer as a whole percent")
    func computeGapBasic() {
        #expect(MonitorGPUWidgetView.computePercent(device: 0.52, renderer: 0.41) == 11)
    }

    @Test("compute gap clamps to zero when Renderer exceeds Device")
    func computeGapClamps() {
        #expect(MonitorGPUWidgetView.computePercent(device: 0.30, renderer: 0.45) == 0)
    }

    @Test("compute gap is nil unless both utilisations are present")
    func computeGapNil() {
        #expect(MonitorGPUWidgetView.computePercent(device: 0.52, renderer: nil) == nil)
        #expect(MonitorGPUWidgetView.computePercent(device: nil, renderer: 0.41) == nil)
    }

    @Test("freshness age is now − sampledAt in whole seconds")
    func freshnessAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let age = MonitorGPUWidgetView.freshnessSeconds(sampledAt: 1_000_000 - 6, now: now)
        #expect(age == 6)
        #expect(MonitorGPUWidgetView.freshnessText(sampledAt: 1_000_000 - 6, now: now) == "6s")
    }

    @Test("a recent sample (~6s) is not stale; missing timestamp reads stale")
    func freshnessNotStale() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        #expect(MonitorGPUWidgetView.isStale(sampledAt: 2_000_000 - 6, now: now) == false)
        #expect(MonitorGPUWidgetView.isStale(sampledAt: nil, now: now) == true)
    }

    @Test("a sample older than the 15s window is stale")
    func freshnessStale() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        #expect(MonitorGPUWidgetView.isStale(sampledAt: 3_000_000 - 20, now: now) == true)
        #expect(MonitorGPUWidgetView.isStale(sampledAt: 3_000_000 - 15, now: now) == false)
        #expect(MonitorGPUWidgetView.isStale(sampledAt: 3_000_000 - 16, now: now) == true)
    }

    @Test("temperature word band: cool < 48 ≤ warm < 58 ≤ hot")
    func temperatureBand() {
        #expect(MonitorGPUWidgetView.tempLabel(40) == "cool")
        #expect(MonitorGPUWidgetView.tempLabel(48) == "warm")
        #expect(MonitorGPUWidgetView.tempLabel(57) == "warm")
        #expect(MonitorGPUWidgetView.tempLabel(58) == "hot")
        #expect(MonitorGPUWidgetView.tempLabel(72) == "hot")
    }

    @Test("all-real series passes through unchanged, in sample order")
    func compactedSeriesAllReal() {
        let times: [Double] = [0, 6, 12, 18]
        let series: [Double?] = [0.1, 0.2, 0.3, 0.4]
        #expect(MonitorGPUWidgetView.compactedSeries(series, times: times, windowSeconds: 60) == [0.1, 0.2, 0.3, 0.4])
    }

    @Test("a nil gap is dropped, not held or interpolated")
    func compactedSeriesDropsNilGap() {
        let times: [Double] = [0, 6, 12, 18, 24]
        let series: [Double?] = [0.1, 0.2, nil, 0.35, 0.4]
        #expect(MonitorGPUWidgetView.compactedSeries(series, times: times, windowSeconds: 60) == [0.1, 0.2, 0.35, 0.4])
    }

    @Test("fewer than 2 real points in the window is absent (nil), not a lone dot")
    func compactedSeriesAbsentBelowTwoPoints() {
        let times: [Double] = [0, 6, 12]
        #expect(MonitorGPUWidgetView.compactedSeries([nil, nil, nil], times: times, windowSeconds: 60) == nil)
        #expect(MonitorGPUWidgetView.compactedSeries([nil, nil, 0.3], times: times, windowSeconds: 60) == nil)
    }

    @Test("exactly 2 real points in the window is present")
    func compactedSeriesPresentAtTwoPoints() {
        let times: [Double] = [0, 6, 12]
        #expect(MonitorGPUWidgetView.compactedSeries([nil, 0.2, 0.3], times: times, windowSeconds: 60) == [0.2, 0.3])
    }

    @Test("samples older than the window cutoff are excluded before compaction")
    func compactedSeriesWindowCutoff() {
        let times: [Double] = [0, 40, 72, 90, 100]
        let series: [Double?] = [0.9, 0.9, 0.1, 0.2, 0.3]
        #expect(MonitorGPUWidgetView.compactedSeries(series, times: times, windowSeconds: 30) == [0.1, 0.2, 0.3])
    }

    @Test("mismatched series/times lengths or an empty timeline yields nil")
    func compactedSeriesGuardsMismatch() {
        #expect(MonitorGPUWidgetView.compactedSeries([0.1, 0.2], times: [0], windowSeconds: 60) == nil)
        #expect(MonitorGPUWidgetView.compactedSeries([], times: [], windowSeconds: 60) == nil)
    }
}
