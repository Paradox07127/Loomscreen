import SwiftUI

public struct DestructiveControlTint: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            // Destructive cue lives in the red label + glyph. The surface stays
            // NEUTRAL — a red-tinted plate behind red text is same-hue on
            // same-hue and reads as low-contrast (worst under Reduce
            // Transparency, where the tint wash is opaque).
            .foregroundStyle(DesignTokens.Colors.Status.danger)
            .tint(DesignTokens.Colors.Status.danger)
            .adaptiveGlassSurface(.roundedRectangle(8), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension View {
    public func destructiveControlTint() -> some View {
        modifier(DestructiveControlTint())
    }
}
