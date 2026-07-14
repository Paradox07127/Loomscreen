import SwiftUI

/// Two series mirrored above/below a centre baseline on a shared scale — the
/// network rx/tx and disk r/w idiom. Ported from the mock's `mirrorSpark`:
/// the primary grows upward from the middle, the secondary downward, both scaled
/// by the combined max so the two sides are directly comparable, with a now-dot
/// at each head. Nil-safe for empty/short series.
struct MirroredAreaChart: View {
    var up: [Double]
    var down: [Double]
    var upColor: Color = MonitorDesign.signalSteel
    var downColor: Color = MonitorDesign.signalSage
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, mid = h / 2
            let scale = sharedMax()

            if up.count >= 2 || down.count >= 2 {
                ZStack {
                    if up.count >= 2 {
                        let pu = poly(up, width: w, mid: mid, up: true, scale: scale)
                        area(pu, mid: mid).fill(gradient(upColor, up: true))
                        line(pu).stroke(upColor, style: stroke)
                        dot(pu.last, color: upColor)
                    }
                    if down.count >= 2 {
                        let pd = poly(down, width: w, mid: mid, up: false, scale: scale)
                        area(pd, mid: mid).fill(gradient(downColor, up: false))
                        line(pd).stroke(downColor, style: stroke)
                        dot(pd.last, color: downColor)
                    }
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: mid))
                        p.addLine(to: CGPoint(x: w, y: mid))
                    }
                    .stroke(MonitorDesign.hairlineHi.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
    }

    private var stroke: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineJoin: .round) }

    private func sharedMax() -> Double {
        let m = max(up.max() ?? 0, down.max() ?? 0, .ulpOfOne)
        return m * 1.15   // headroom, matching the mock
    }

    private func poly(_ arr: [Double], width: CGFloat, mid: CGFloat, up: Bool, scale: Double) -> [CGPoint] {
        let n = arr.count
        let extent = mid - 2
        return arr.enumerated().map { i, v in
            let x = CGFloat(i) / CGFloat(max(n - 1, 1)) * width
            let f = CGFloat(min(1, max(0, v / scale)))
            let y = up ? mid - f * extent : mid + f * extent
            return CGPoint(x: x, y: y)
        }
    }

    private func line(_ pts: [CGPoint]) -> Path {
        var p = Path(); p.addLines(pts); return p
    }

    private func area(_ pts: [CGPoint], mid: CGFloat) -> Path {
        var p = Path()
        guard let first = pts.first, let last = pts.last else { return p }
        // Explicit lines, not `addLines` (whose implicit `move` would drop the
        // mid-baseline start and fill a chord instead of the area to the axis).
        p.move(to: CGPoint(x: first.x, y: mid))
        for point in pts { p.addLine(to: point) }
        p.addLine(to: CGPoint(x: last.x, y: mid))
        p.closeSubpath()
        return p
    }

    private func gradient(_ color: Color, up: Bool) -> LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.5), color.opacity(0)],
            startPoint: up ? .bottom : .top,
            endPoint: up ? .top : .bottom
        )
    }

    @ViewBuilder
    private func dot(_ point: CGPoint?, color: Color) -> some View {
        if let point {
            Circle().fill(color).frame(width: 6, height: 6).position(point)
                .shadow(color: color.opacity(0.6), radius: 3)
        }
    }
}

#Preview("Mirrored area") {
    MirroredAreaChart(
        up: [3.1, 4.2, 5.5, 6.8, 5.2, 4.1, 6.3, 8.1, 7.2, 5.4],
        down: [0.4, 0.6, 0.9, 0.7, 0.5, 0.8, 1.1, 0.9, 0.6, 0.5]
    )
    .frame(width: 260, height: 64)
    .padding(24)
    .background(MonitorDesign.boardWash)
}
