import SwiftUI

struct TickTrack: View {
    /// Event timestamps as seconds-since-reference (any monotonic epoch matching
    /// `now`). Events older than `span` or in the future are dropped.
    var events: [Double]
    /// The reference "now" in the same units as `events`.
    var now: Double
    /// Trailing window length in seconds.
    var span: Double = 180
    var tint: Color = MonitorDesign.signalAmber
    var cornerRadius: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(colors: [MonitorDesign.bg0.opacity(0.55),
                                                MonitorDesign.bg0.opacity(0.3)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                Rectangle()
                    .fill(MonitorDesign.hairline.opacity(0.5))
                    .frame(height: 1)

                ForEach(Array(Self.ticks(events: events, now: now, span: span).enumerated()),
                        id: \.offset) { _, t in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(tint)
                        .frame(width: 1.5, height: h * CGFloat(t.heightFraction))
                        .shadow(color: tint.opacity(0.6), radius: 2)
                        .opacity(0.9)
                        .position(x: CGFloat(t.x) * w, y: h - h * CGFloat(t.heightFraction) / 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    // MARK: - Pure geometry

    struct Tick: Equatable {
        /// Normalised x 0…1 (0 = oldest edge, 1 = now).
        let x: Double
        /// Height fraction 0…1 — taller for more-recent events.
        let heightFraction: Double
    }

    nonisolated static func ticks(events: [Double], now: Double, span: Double) -> [Tick] {
        guard span > 0 else { return [] }
        return events.compactMap { ts in
            let age = now - ts
            if age < 0 || age > span { return nil }
            let recency = 1 - age / span              // 0 (old) … 1 (now)
            let height = 0.38 + recency * 0.46
            return Tick(x: recency, heightFraction: height)
        }
    }
}

#Preview("Tick track") {
    let now = 10_000.0
    return VStack(spacing: 16) {
        TickTrack(events: [9_990, 9_960, 9_930, 9_880, 9_840].map(Double.init), now: now)
            .frame(width: 260, height: 20)
        TickTrack(events: (0..<12).map { now - Double($0) * 14 }, now: now,
                  tint: MonitorDesign.signalSage)
            .frame(width: 260, height: 20)
    }
    .padding(24)
    .background(MonitorDesign.boardWash)
}
