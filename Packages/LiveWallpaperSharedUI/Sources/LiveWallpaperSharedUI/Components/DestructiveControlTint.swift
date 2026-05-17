import SwiftUI

public struct DestructiveControlTint: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.red)
            .tint(Color.red)
            .adaptiveGlassSurface(.roundedRectangle(8), tint: .red, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension View {
    public func destructiveControlTint() -> some View {
        modifier(DestructiveControlTint())
    }
}
