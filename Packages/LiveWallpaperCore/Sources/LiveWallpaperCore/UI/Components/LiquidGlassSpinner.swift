import SwiftUI

/// Two stacked rotating arcs kept gentle so the motion doesn't compete with
/// the underlying GIF preview that fades through during the loading phase.
public struct LiquidGlassSpinner: View {
    public var size: CGFloat = 44
    public var lineWidth: CGFloat = 4
    public var tint: Color = .white
    public var progressText: String?

    @State private var animate = false

    public init(
        size: CGFloat = 44,
        lineWidth: CGFloat = 4,
        tint: Color = .white,
        progressText: String? = nil
    ) {
        self.size = size
        self.lineWidth = lineWidth
        self.tint = tint
        self.progressText = progressText
    }

    public var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.12), lineWidth: lineWidth)

                Circle()
                    .trim(from: 0, to: 0.32)
                    .stroke(
                        tint.opacity(0.85),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(animate ? 360 : 0))
                    .blendMode(.plusLighter)
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: animate)

                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(
                        tint.opacity(0.55),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(animate ? -360 : 0))
                    .blendMode(.plusLighter)
                    .animation(.linear(duration: 1.7).repeatForever(autoreverses: false), value: animate)
            }
            .frame(width: size, height: size)

            if let progressText {
                Text(verbatim: progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .thumbnailBadgeGlass()
                    .accessibilityLabel(Text(verbatim: progressText))
            }
        }
        .onAppear { animate = true }
        .accessibilityElement(children: progressText == nil ? .ignore : .contain)
    }
}
