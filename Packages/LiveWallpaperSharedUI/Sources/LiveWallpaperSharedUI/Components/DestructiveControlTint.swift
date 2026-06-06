import SwiftUI

public struct DestructiveControlTint: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .foregroundStyle(DesignTokens.Colors.Status.danger)
            .tint(DesignTokens.Colors.Status.danger)
            .adaptiveGlassSurface(.roundedRectangle(8), tint: DesignTokens.Colors.Status.danger, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension View {
    public func destructiveControlTint() -> some View {
        modifier(DestructiveControlTint())
    }
}
