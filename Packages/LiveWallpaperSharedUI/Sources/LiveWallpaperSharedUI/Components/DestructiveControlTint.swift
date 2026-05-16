import SwiftUI

public struct DestructiveControlTint: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.red)
            .tint(Color.red)
            .glassEffect(
                .regular.tint(Color.red.opacity(0.16)).interactive(),
                in: .rect(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension View {
    public func destructiveControlTint() -> some View {
        modifier(DestructiveControlTint())
    }
}
