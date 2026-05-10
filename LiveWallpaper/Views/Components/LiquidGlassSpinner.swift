import SwiftUI

/// Custom Liquid Glass loading indicator. Used by the scene detail card while
/// the SpriteKit runtime is decoding image layers. Two stacked rotating arcs
/// keep the motion gentle so it doesn't compete with the underlying GIF
/// preview that fades through during the loading phase.
struct LiquidGlassSpinner: View {
    var size: CGFloat = 44
    var lineWidth: CGFloat = 4
    var tint: Color = .white
    /// Optional caption rendered just below the spinner ring. Used by
    /// Phase 2.1's per-layer progress (e.g. "Decoding 3/12 textures…")
    /// without forcing every caller to wrap the spinner in a VStack.
    var progressText: String?

    @State private var animate = false

    var body: some View {
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
                    // ultraThinMaterial pill keeps the caption visually
                    // tied to the Liquid Glass aesthetic instead of
                    // floating as plain white text on the blurred
                    // wallpaper background.
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityLabel(Text(verbatim: progressText))
            }
        }
        .onAppear { animate = true }
        // Keep the ring itself silent so VoiceOver only announces the
        // progress caption (when present) — avoids "loading, loading,
        // loading…" chatter.
        .accessibilityElement(children: progressText == nil ? .ignore : .contain)
    }
}

#Preview {
    LiquidGlassSpinner()
        .padding(48)
        .background(.black)
}
