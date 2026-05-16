import SwiftUI

/// Custom Liquid Glass loading indicator. Used by the scene detail card while
/// the renderer is decoding image layers. Two stacked rotating arcs keep
/// the motion gentle so it doesn't compete with the underlying GIF preview
/// that fades through during the loading phase.
public struct LiquidGlassSpinner: View {
    public var size: CGFloat = 44
    public var lineWidth: CGFloat = 4
    public var tint: Color = .white
    /// Optional caption rendered just below the spinner ring. Used by
    /// Phase 2.1's per-layer progress (e.g. "Decoding 3/12 textures…")
    /// without forcing every caller to wrap the spinner in a VStack.
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
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityLabel(Text(verbatim: progressText))
            }
        }
        .onAppear { animate = true }
        .accessibilityElement(children: progressText == nil ? .ignore : .contain)
    }
}
