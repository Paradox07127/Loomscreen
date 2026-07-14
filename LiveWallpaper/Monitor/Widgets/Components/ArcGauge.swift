import AppKit
import SwiftUI

/// The ONE shared utilisation arc (SPEC §3.0-a): CPU, GPU, ANE power and quota
/// rings all reuse this so the family reads pixel-identically. Geometry is ported
/// from the mock's `arcGauge()`: 12 wedges over a 276° sweep starting at −228°,
/// a 6° gap between wedges, band-coloured lit segments, an em-dash "no reading"
/// mode, and an optional peak marker.
/// One coloured segment of a multi-band gauge: `value` is its own 0…1 slice of
/// the ring, coloured with `color` (e.g. CPU user=amber, system=steel). Bands are
/// laid down cumulatively from the start of the arc.
struct ArcBand: Equatable {
    var value: Double
    var color: Color
    init(_ value: Double, _ color: Color) {
        self.value = value
        self.color = color
    }
}

struct ArcGauge<Center: View>: View {
    /// Utilisation fraction 0…1. `nil` renders the dashed "no sample" gauge.
    var value: Double?
    /// Override the band colour (e.g. a fixed steel for power); default follows
    /// `MonitorDesign.loadBandColor(value)`.
    var color: Color?
    /// Optional peak marker fraction 0…1, drawn as a tick on the track.
    var peak: Double?
    /// When set, lit wedges are coloured per cumulative band (e.g. user then
    /// system) instead of the single `color`/band colour; `value` still drives how
    /// many wedges light and the centre readout.
    var bands: [ArcBand]?
    var lineWidth: CGFloat = 9
    @ViewBuilder var center: () -> Center

    private let segmentCount = 12
    private let startAngle = -228.0
    private let sweep = 276.0
    private let gapDegrees = 6.0
    private let radiusFraction = 0.40   // rad 40 in a 100-unit box

    @Environment(\.monitorReduceMotion) private var reduceMotion

    init(
        value: Double?,
        color: Color? = nil,
        peak: Double? = nil,
        bands: [ArcBand]? = nil,
        lineWidth: CGFloat = 9,
        @ViewBuilder center: @escaping () -> Center
    ) {
        self.value = value
        self.color = color
        self.peak = peak
        self.bands = bands
        self.lineWidth = lineWidth
        self.center = center
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Canvas { ctx, size in
                    draw(in: ctx, size: size)
                }
                .frame(width: side, height: side)

                center()
                    .frame(width: side * 0.62, height: side * 0.62)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: value ?? -1)
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = side * radiusFraction
        let stroke = lineWidth / 100 * side

        let fraction = value.map { min(1, max(0, $0)) }
        let lit = fraction.map { Int(($0 * Double(segmentCount)).rounded()) } ?? 0
        let litColor = color ?? MonitorDesign.loadBandColor(fraction ?? 0)
        let per = sweep / Double(segmentCount)
        let isEmpty = (value == nil)

        for i in 0..<segmentCount {
            let a0 = startAngle + Double(i) * per + gapDegrees / 2
            let a1 = startAngle + Double(i + 1) * per - gapDegrees / 2
            var path = Path()
            path.addArc(
                center: center,
                radius: radius,
                startAngle: .degrees(a0),
                endAngle: .degrees(a1),
                clockwise: false
            )
            let on = i < lit
            let strokeColor: Color = isEmpty
                ? MonitorDesign.hairlineHi.opacity(0.7)
                : (on ? segmentColor(i, fallback: litColor) : MonitorDesign.track)
            let style = StrokeStyle(
                lineWidth: stroke,
                lineCap: .round,
                dash: isEmpty ? [stroke * 0.33, stroke * 0.5] : []
            )
            ctx.stroke(path, with: .color(strokeColor), style: style)
        }

        // Peak marker: a short radial tick just outside the value ring.
        if let peak, !isEmpty {
            let pf = min(1, max(0, peak))
            let angle = (startAngle + pf * sweep) * .pi / 180
            let inner = radius - stroke * 0.7
            let outer = radius + stroke * 0.7
            var tick = Path()
            tick.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            tick.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            ctx.stroke(tick, with: .color(MonitorDesign.inkPrimary.opacity(0.9)),
                       style: StrokeStyle(lineWidth: stroke * 0.28, lineCap: .round))
        }
    }

    /// Colour of lit wedge `i`: when `bands` is set, the band whose cumulative
    /// range covers the wedge's mid-fraction; otherwise the single `fallback`.
    private func segmentColor(_ i: Int, fallback: Color) -> Color {
        guard let bands, !bands.isEmpty else { return fallback }
        let mid = (Double(i) + 0.5) / Double(segmentCount)
        var acc = 0.0
        for band in bands {
            acc += max(0, band.value)
            if mid < acc { return band.color }
        }
        return bands.last?.color ?? fallback
    }
}

extension ArcGauge where Center == EmptyView {
    init(value: Double?, color: Color? = nil, peak: Double? = nil, bands: [ArcBand]? = nil, lineWidth: CGFloat = 9) {
        self.init(value: value, color: color, peak: peak, bands: bands, lineWidth: lineWidth) { EmptyView() }
    }
}

#Preview("Arc gauge") {
    HStack(spacing: 24) {
        ForEach([0.22, 0.58, 0.91], id: \.self) { v in
            ArcGauge(value: v, peak: min(1, v + 0.12)) {
                VStack(spacing: 0) {
                    Text("\(Int(v * 100))")
                        .font(MonitorDesign.heroFont(size: 30))
                        .monospacedDigit()
                        .foregroundStyle(MonitorDesign.inkPrimary)
                    Text("%").font(MonitorDesign.labelFont(size: 10))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
            }
            .frame(width: 110, height: 110)
        }
        ArcGauge(value: nil) {
            Text("—").font(MonitorDesign.heroFont(size: 28))
                .foregroundStyle(MonitorDesign.inkFaint)
        }
        .frame(width: 110, height: 110)
    }
    .padding(32)
    .background(MonitorDesign.boardWash)
}
