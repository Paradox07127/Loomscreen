import Testing
import SwiftUI
@testable import LiveWallpaper

struct MonitorDesignTests {

    private let tol = 0.01

    private func approx(_ a: Double, _ b: Double, _ t: Double, _ label: String) {
        #expect(abs(a - b) <= t, "\(label): \(a) vs \(b) (Δ \(abs(a - b)))")
    }

    @Test("White edge oklch(1 0 0) → sRGB white")
    func whiteEdge() {
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 1, c: 0, h: 0)
        approx(r, 1, tol, "r"); approx(g, 1, tol, "g"); approx(b, 1, tol, "b")
    }

    @Test("Black edge oklch(0 0 0) → sRGB black")
    func blackEdge() {
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 0, c: 0, h: 0)
        approx(r, 0, tol, "r"); approx(g, 0, tol, "g"); approx(b, 0, tol, "b")
    }

    @Test("Mid green oklch(0.62 0.19 145) is green-dominant")
    func midGreen() {
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 0.62, c: 0.19, h: 145)
        approx(r, 0.067, tol, "r"); approx(g, 0.634, tol, "g"); approx(b, 0.185, tol, "b")
        #expect(g > r && g > b, "green channel should dominate")
    }

    @Test("Amber signal matches the mock's hand-converted sRGB")
    func amberReference() {
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 0.80, c: 0.128, h: 78)
        approx(r, 0.921, tol, "r"); approx(g, 0.701, tol, "g"); approx(b, 0.334, tol, "b")
    }

    @Test("Coral signal matches the mock's hand-converted sRGB")
    func coralReference() {
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 0.705, c: 0.165, h: 34)
        approx(r, 0.959, tol, "r"); approx(g, 0.453, tol, "g"); approx(b, 0.340, tol, "b")
    }

    @Test("Sage signal matches the mock's hand-converted sRGB")
    func sageReference() {
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 0.76, c: 0.10, h: 158)
        approx(r, 0.469, tol, "r"); approx(g, 0.771, tol, "g"); approx(b, 0.599, tol, "b")
    }

    @Test("Ink primary matches the mock's hand-converted sRGB")
    func inkReference() {
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 0.93, c: 0.012, h: 84)
        approx(r, 0.924, tol, "r"); approx(g, 0.907, tol, "g"); approx(b, 0.875, tol, "b")
    }

    @Test("Linear components stay inside the unit gamut")
    func linearInGamut() {
        let (r, g, b) = MonitorDesign.linearSRGB(l: 0.62, c: 0.045, h: 250)
        for v in [r, g, b] { #expect(v >= 0 && v <= 1) }
    }

    @Test("Load band identity crosses at 0.4 and 0.8")
    func loadBandThresholds() {
        #expect(MonitorDesign.loadBand(0.0) == .low)
        #expect(MonitorDesign.loadBand(0.39) == .low)
        #expect(MonitorDesign.loadBand(0.40) == .mid)
        #expect(MonitorDesign.loadBand(0.79) == .mid)
        #expect(MonitorDesign.loadBand(0.80) == .mid)
        #expect(MonitorDesign.loadBand(0.801) == .high)
        #expect(MonitorDesign.loadBand(1.0) == .high)
    }

    @Test("Load band colour matches the band identity at each side")
    func loadBandColorMatchesTokens() {
        #expect(colorEq(MonitorDesign.loadBandColor(0.2), MonitorDesign.loadSteel))
        #expect(colorEq(MonitorDesign.loadBandColor(0.6), MonitorDesign.signalAmber))
        #expect(colorEq(MonitorDesign.loadBandColor(0.95), MonitorDesign.signalCoral))
    }

    @Test("Type scale honours the mock's clamps")
    func typeScale() {
        let small = MonitorDesign.TypeScale(cellHeight: 60)
        approx(small.hero, 24, 1e-9, "hero floor")
        let mid = MonitorDesign.TypeScale(cellHeight: 100)
        approx(mid.hero, 36, 1e-9, "hero mid")
        approx(mid.sub, 36 * 0.52, 1e-9, "sub")
        let big = MonitorDesign.TypeScale(cellHeight: 200)
        approx(big.hero, 46, 1e-9, "hero cap")
        approx(big.label, 12, 1e-9, "label cap")
    }

    @Test("Ticks map recency to x and height; out-of-window dropped")
    func tickFade() {
        let now = 1000.0
        let ticks = TickTrack.ticks(events: [1000, 910, 820, 500, 1100], now: now, span: 180)
        #expect(ticks.count == 3)
        approx(ticks[0].x, 1.0, 1e-9, "recent x")
        approx(ticks[0].heightFraction, 0.84, 1e-9, "recent height")
        approx(ticks[1].x, 0.5, 1e-9, "mid x")
        approx(ticks[1].heightFraction, 0.38 + 0.5 * 0.46, 1e-9, "mid height")
        approx(ticks[2].x, 0.0, 1e-9, "old x")
        approx(ticks[2].heightFraction, 0.38, 1e-9, "old height")
    }

    @Test("Zero/negative span yields no ticks")
    func tickZeroSpan() {
        #expect(TickTrack.ticks(events: [1, 2, 3], now: 3, span: 0).isEmpty)
    }

    @Test("Heatmap opacity floor keeps idle legible and saturates at 1")
    func heatmapOpacity() {
        approx(HeatmapGrid.rampOpacity(0), 0.12, 1e-9, "floor")
        approx(HeatmapGrid.rampOpacity(1), 1.0, 1e-9, "ceil")
        approx(HeatmapGrid.rampOpacity(0.5), 0.12 + 0.5 * 0.88, 1e-9, "mid")
        approx(HeatmapGrid.rampOpacity(-1), 0.12, 1e-9, "clamped low")
    }

    @Test("Heatmap fill switches to coral above the 0.8 band")
    func heatmapRampColor() {
        #expect(colorEq(HeatmapGrid.rampColor(0.5), MonitorDesign.signalAmber))
        #expect(colorEq(HeatmapGrid.rampColor(0.9), MonitorDesign.signalCoral))
    }

    @Test("Temperature ramp anchors at sage / amber / coral")
    func temperatureAnchors() {
        let cool = MonitorDesign.gammaSRGB(l: 0.74, c: 0.09, h: 158)
        #expect(cool.1 > cool.0, "cool end is green-dominant")
        let hot = MonitorDesign.gammaSRGB(l: 0.70, c: 0.165, h: 30)
        #expect(hot.0 > hot.1, "hot end is red-dominant")
    }
}

private func colorEq(_ a: Color, _ b: Color) -> Bool {
    let ra = a.resolve(in: .init())
    let rb = b.resolve(in: .init())
    return abs(ra.red - rb.red) < 0.001
        && abs(ra.green - rb.green) < 0.001
        && abs(ra.blue - rb.blue) < 0.001
}
