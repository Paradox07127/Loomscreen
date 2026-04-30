import SwiftUI

/// Custom Liquid Glass loading indicator. Used by the scene detail card while
/// the SpriteKit runtime is decoding image layers. Two stacked rotating arcs
/// keep the motion gentle so it doesn't compete with the underlying GIF
/// preview that fades through during the loading phase.
struct LiquidGlassSpinner: View {
    var size: CGFloat = 44
    var lineWidth: CGFloat = 4
    var tint: Color = .white

    @State private var animate = false

    var body: some View {
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
        .onAppear { animate = true }
        .accessibilityHidden(true)
    }
}

#Preview {
    LiquidGlassSpinner()
        .padding(48)
        .background(.black)
}
