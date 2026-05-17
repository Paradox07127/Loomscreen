import SwiftUI

/// Reusable glass-capsule button style for detail controls.
public struct GlassCapsuleButtonStyle: ButtonStyle {
    public var tint: Color = .accentColor
    public var fontSize: CGFloat = 12
    public var horizontalPadding: CGFloat = 10
    public var verticalPadding: CGFloat = 5

    public init(
        tint: Color = .accentColor,
        fontSize: CGFloat = 12,
        horizontalPadding: CGFloat = 10,
        verticalPadding: CGFloat = 5
    ) {
        self.tint = tint
        self.fontSize = fontSize
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    public func makeBody(configuration: Configuration) -> some View {
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
                .adaptiveGlassSurface(.capsule, tint: effectiveTint, interactive: true)
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1.0) : 0.45)
        }
    }
}
