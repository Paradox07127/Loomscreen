import Testing
import SwiftUI
@testable import LiveWallpaper

/// Pure-value tests for the Monitor widget design system: the OKLCH colour
/// transform (against known references), the shared load-band thresholds, the
/// concentric-radius math, the tick-track age-fade, and the heatmap ramp.
struct MonitorDesignTests {

    private let tol = 0.01

    private func approx(_ a: Double, _ b: Double, _ t: Double, _ label: String) {
        #expect(abs(a - b) <= t, "\(label): \(a) vs \(b) (Δ \(abs(a - b)))")
    }

    // MARK: - OKLCH → sRGB (gamma-encoded reference values)

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
        // Reference from the verified transform: ~ (0.067, 0.634, 0.185)
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 0.62, c: 0.19, h: 145)
        approx(r, 0.067, tol, "r"); approx(g, 0.634, tol, "g"); approx(b, 0.185, tol, "b")
        #expect(g > r && g > b, "green channel should dominate")
    }

    @Test("Amber signal matches the mock's hand-converted sRGB")
    func amberReference() {
        // --run oklch(0.80 0.128 78) → HUD used (0.921, 0.701, 0.334)
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 0.80, c: 0.128, h: 78)
        approx(r, 0.921, tol, "r"); approx(g, 0.701, tol, "g"); approx(b, 0.334, tol, "b")
    }

    @Test("Coral signal matches the mock's hand-converted sRGB")
    func coralReference() {
        // --need oklch(0.705 0.165 34) → HUD used (0.959, 0.453, 0.340)
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 0.705, c: 0.165, h: 34)
        approx(r, 0.959, tol, "r"); approx(g, 0.453, tol, "g"); approx(b, 0.340, tol, "b")
    }

    @Test("Sage signal matches the mock's hand-converted sRGB")
    func sageReference() {
        // --done oklch(0.76 0.10 158) → HUD used (0.469, 0.771, 0.599)
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 0.76, c: 0.10, h: 158)
        approx(r, 0.469, tol, "r"); approx(g, 0.771, tol, "g"); approx(b, 0.599, tol, "b")
    }

    @Test("Ink primary matches the mock's hand-converted sRGB")
    func inkReference() {
        // --ink oklch(0.93 0.012 84) → HUD used (0.924, 0.907, 0.875)
        let (r, g, b) = MonitorDesign.gammaSRGB(l: 0.93, c: 0.012, h: 84)
        approx(r, 0.924, tol, "r"); approx(g, 0.907, tol, "g"); approx(b, 0.875, tol, "b")
    }

    @Test("Linear components stay inside the unit gamut")
    func linearInGamut() {
        let (r, g, b) = MonitorDesign.linearSRGB(l: 0.62, c: 0.045, h: 250)
        for v in [r, g, b] { #expect(v >= 0 && v <= 1) }
    }

    // MARK: - Load band thresholds (mock loadBandColor)

    @Test("Load band identity crosses at 0.4 and 0.8")
    func loadBandThresholds() {
        #expect(MonitorDesign.loadBand(0.0) == .low)
        #expect(MonitorDesign.loadBand(0.39) == .low)
        #expect(MonitorDesign.loadBand(0.40) == .mid)   // >= 0.4
        #expect(MonitorDesign.loadBand(0.79) == .mid)
        #expect(MonitorDesign.loadBand(0.80) == .mid)   // not yet high (> 0.8)
        #expect(MonitorDesign.loadBand(0.801) == .high)
        #expect(MonitorDesign.loadBand(1.0) == .high)
    }

    @Test("Load band colour matches the band identity at each side")
    func loadBandColorMatchesTokens() {
        // Steel low, amber mid, coral high — sampled well inside each band.
        #expect(colorEq(MonitorDesign.loadBandColor(0.2), MonitorDesign.loadSteel))
        #expect(colorEq(MonitorDesign.loadBandColor(0.6), MonitorDesign.signalAmber))
        #expect(colorEq(MonitorDesign.loadBandColor(0.95), MonitorDesign.signalCoral))
    }

    // MARK: - Type scale clamps (SPEC §3.0)

    @Test("Type scale honours the mock's clamps")
    func typeScale() {
        let small = MonitorDesign.TypeScale(cellHeight: 60)     // 60*.36 = 21.6 → floor 24
        approx(small.hero, 24, 1e-9, "hero floor")
        let mid = MonitorDesign.TypeScale(cellHeight: 100)      // 100*.36 = 36
        approx(mid.hero, 36, 1e-9, "hero mid")
        approx(mid.sub, 36 * 0.52, 1e-9, "sub")
        let big = MonitorDesign.TypeScale(cellHeight: 200)      // 200*.36 = 72 → cap 46
        approx(big.hero, 46, 1e-9, "hero cap")
        approx(big.label, 12, 1e-9, "label cap")
    }

    // MARK: - TickTrack age fade

    @Test("Ticks map recency to x and height; out-of-window dropped")
    func tickFade() {
        let now = 1000.0
        let ticks = TickTrack.ticks(events: [1000, 910, 820, 500, 1100], now: now, span: 180)
        // 1000 (age 0), 910 (age 90), 820 (age 180 → boundary kept); 500 too old, 1100 future.
        #expect(ticks.count == 3)
        // Most recent: x≈1, height≈0.84
        approx(ticks[0].x, 1.0, 1e-9, "recent x")
        approx(ticks[0].heightFraction, 0.84, 1e-9, "recent height")
        // Half-window: x≈0.5, height≈0.61
        approx(ticks[1].x, 0.5, 1e-9, "mid x")
        approx(ticks[1].heightFraction, 0.38 + 0.5 * 0.46, 1e-9, "mid height")
        // Oldest at boundary: x≈0, height floor 0.38
        approx(ticks[2].x, 0.0, 1e-9, "old x")
        approx(ticks[2].heightFraction, 0.38, 1e-9, "old height")
    }

    @Test("Zero/negative span yields no ticks")
    func tickZeroSpan() {
        #expect(TickTrack.ticks(events: [1, 2, 3], now: 3, span: 0).isEmpty)
    }

    // MARK: - Heatmap ramp

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

    // MARK: - Temperature ramp anchors (mock tempColor)

    @Test("Temperature ramp anchors at sage / amber / coral")
    func temperatureAnchors() {
        // 34°C → sage-ish (green > red), 70°C → coral-ish (red > green).
        let cool = MonitorDesign.gammaSRGB(l: 0.74, c: 0.09, h: 158)  // t=0 anchor
        #expect(cool.1 > cool.0, "cool end is green-dominant")
        let hot = MonitorDesign.gammaSRGB(l: 0.70, c: 0.165, h: 30)   // t=1 anchor
        #expect(hot.0 > hot.1, "hot end is red-dominant")
    }
}

/// Colour identity via SwiftUI's resolved sRGB components (macOS 14+).
private func colorEq(_ a: Color, _ b: Color) -> Bool {
    let ra = a.resolve(in: .init())
    let rb = b.resolve(in: .init())
    return abs(ra.red - rb.red) < 0.001
        && abs(ra.green - rb.green) < 0.001
        && abs(ra.blue - rb.blue) < 0.001
}
