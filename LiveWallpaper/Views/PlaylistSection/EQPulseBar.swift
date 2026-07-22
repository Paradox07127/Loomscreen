import SwiftUI

/// 3-bar audio-style equalizer indicator for the currently-playing row.
struct EQPulseBar: View {
    let isPlaying: Bool
    var tint: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || !isPlaying {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { idx in
                    bar(forHeightFactor: staticHeights[idx])
                }
            }
            .frame(width: 14, height: 12)
            .accessibilityHidden(true)
        } else {
            TimelineView(.animation(minimumInterval: 0.05, paused: !isPlaying)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2) {
                    bar(forHeightFactor: heightFactor(at: t, phase: 0.0))
                    bar(forHeightFactor: heightFactor(at: t, phase: 0.33))
                    bar(forHeightFactor: heightFactor(at: t, phase: 0.66))
                }
            }
            .frame(width: 14, height: 12)
            .accessibilityHidden(true)
        }
    }

    private static let minHeight: CGFloat = 0.30
    private static let maxHeight: CGFloat = 1.0
    private let staticHeights: [CGFloat] = [0.55, 0.85, 0.40]

    @ViewBuilder
    private func bar(forHeightFactor factor: CGFloat) -> some View {
        GeometryReader { proxy in
            let h = proxy.size.height * factor
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(tint)
                .frame(width: proxy.size.width, height: max(h, 1))
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: 3)
    }

    /// Per-bar `phase` offset so the three columns animate out of sync.
    private func heightFactor(at time: TimeInterval, phase: Double) -> CGFloat {
        let period = 0.6
        let normalized = (time.truncatingRemainder(dividingBy: period)) / period
        let theta = (normalized + phase) * .pi * 2
        let amplitude = (Self.maxHeight - Self.minHeight) / 2
        let mid = Self.minHeight + amplitude
        return mid + amplitude * CGFloat(sin(theta))
    }
}
