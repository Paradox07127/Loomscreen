import SwiftUI

/// Reusable glass-capsule button style for detail controls.
struct GlassCapsuleButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var fontSize: CGFloat = 12
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(
            configuration: configuration,
            tint: tint,
            fontSize: fontSize,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        )
    }

    /// Inner view so we can read `\.isEnabled` (ButtonStyle.Configuration doesn't expose it).
    private struct StyledLabel: View {
        let configuration: Configuration
        let tint: Color
        let fontSize: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let effectiveTint = isEnabled ? tint : Color.secondary
            configuration.label
                .font(.system(size: fontSize))
                .foregroundStyle(effectiveTint)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .glassEffect(
                    .regular.tint(effectiveTint.opacity(isEnabled ? 0.15 : 0.06)).interactive(),
                    in: .capsule
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1.0) : 0.45)
        }
    }
}
