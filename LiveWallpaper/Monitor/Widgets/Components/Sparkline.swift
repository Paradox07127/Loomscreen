import SwiftUI

/// A history series → line path with an optional gradient area fill and a "now"
/// dot at the last point. Ported from the mock's `segSpark`: the stroke can
/// follow the per-sample load band (steel/amber/coral) so a busy stretch reads
/// amber/coral, and the baseline + optional mid guides frame it. Nil-safe for
/// empty or single-point series.
struct Sparkline: View {
    var values: [Double]
    /// y-domain. `nil` auto-scales to the data (with headroom); pass a fixed
    /// range for a stable axis (e.g. 0…1 for load).
    var domain: ClosedRange<Double>?
    /// When true (and the domain is 0…1-like), colour the stroke by load band at
    /// each sample; otherwise use `lineColor`.
    var bandColored: Bool = false
    var lineColor: Color = MonitorDesign.signalAmber
    var showArea: Bool = true
    /// Optional horizontal guide lines expressed in domain units (e.g. 0.4/0.8).
    var guides: [Double] = []
    var lineWidth: CGFloat = 1.6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let (lo, hi) = resolvedDomain()
            let span = max(hi - lo, .ulpOfOne)

            if let pts = points(in: geo.size, lo: lo, span: span), pts.count >= 1 {
                ZStack {
                    baseline(w: w, h: h)
                    ForEach(Array(guides.enumerated()), id: \.offset) { _, g in
                        let y = h - CGFloat((g - lo) / span) * h
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(MonitorDesign.hairlineHi.opacity(0.3),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }

                    if showArea, pts.count >= 2 {
                        areaPath(pts, height: h)
                            .fill(
                                LinearGradient(
                                    colors: [areaColor().opacity(0.26), areaColor().opacity(0)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }

                    if pts.count >= 2 {
                        linePath(pts).stroke(strokeStyleColor(pts),
                                             style: StrokeStyle(lineWidth: lineWidth,
                                                                lineCap: .round, lineJoin: .round))
                    }

                    if let last = pts.last {
                        Circle()
                            .fill(nowColor())
                            .frame(width: 6, height: 6)
                            .position(last)
                            .shadow(color: nowColor().opacity(0.6), radius: 3)
                    }
                }
            }
        }
    }

    // MARK: - Geometry

    private func resolvedDomain() -> (Double, Double) {
        if let domain { return (domain.lowerBound, domain.upperBound) }
        guard let lo = values.min(), let hi = values.max() else { return (0, 1) }
        if hi == lo { return (lo - 0.5, hi + 0.5) }
        let pad = (hi - lo) * 0.12
        return (lo, hi + pad)
    }

    private func points(in size: CGSize, lo: Double, span: Double) -> [CGPoint]? {
        guard !values.isEmpty else { return nil }
        let n = values.count
        let h = size.height
        if n == 1 {
            let y = h - CGFloat((values[0] - lo) / span) * h
            return [CGPoint(x: size.width, y: y)]
        }
        return values.enumerated().map { i, v in
            let x = CGFloat(i) / CGFloat(n - 1) * size.width
            let y = h - CGFloat((v - lo) / span) * h
            return CGPoint(x: x, y: min(h, max(0, y)))
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        return p
    }

    private func areaPath(_ pts: [CGPoint], height: CGFloat) -> Path {
        var p = Path()
        guard let first = pts.first, let last = pts.last else { return p }
        p.move(to: CGPoint(x: first.x, y: height))
        p.addLines(pts)
        p.addLine(to: CGPoint(x: last.x, y: height))
        p.closeSubpath()
        return p
    }

    // MARK: - Colour

    private var lastFraction: Double { values.last ?? 0 }

    private func areaColor() -> Color {
        bandColored ? MonitorDesign.loadBandColor(lastFraction) : lineColor
    }

    private func nowColor() -> Color {
        bandColored ? MonitorDesign.loadBandColor(lastFraction) : lineColor
    }

    /// Band-coloured mode uses a horizontal gradient keyed to each sample's band;
    /// otherwise a solid stroke.
    private func strokeStyleColor(_ pts: [CGPoint]) -> some ShapeStyle {
        if bandColored, pts.count >= 2 {
            let stops = values.enumerated().map { i, v -> Gradient.Stop in
                Gradient.Stop(color: MonitorDesign.loadBandColor(v),
                              location: CGFloat(i) / CGFloat(values.count - 1))
            }
            return AnyShapeStyle(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(lineColor)
    }

    private func baseline(w: CGFloat, h: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: h - 1))
            p.addLine(to: CGPoint(x: w, y: h - 1))
        }
        .stroke(MonitorDesign.hairline.opacity(0.45), lineWidth: 1)
    }
}

#Preview("Sparkline") {
    VStack(spacing: 20) {
        Sparkline(values: [0.2, 0.35, 0.28, 0.55, 0.72, 0.68, 0.9, 0.84],
                  domain: 0...1, bandColored: true, guides: [0.4, 0.8])
            .frame(width: 260, height: 60)

        Sparkline(values: [12, 18, 14, 22, 31, 26, 20, 24].map(Double.init),
                  lineColor: MonitorDesign.signalSteel)
            .frame(width: 260, height: 60)

        Sparkline(values: [], domain: 0...1)
            .frame(width: 260, height: 40)
            .overlay(Text("empty").font(MonitorDesign.captionFont(size: 11))
                .foregroundStyle(MonitorDesign.inkFaint))
    }
    .padding(24)
    .background(MonitorDesign.boardWash)
}
