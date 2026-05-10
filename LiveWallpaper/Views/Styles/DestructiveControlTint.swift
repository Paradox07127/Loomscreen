import SwiftUI

struct DestructiveControlTint: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.red)
            .tint(Color.red)
    }
}

extension View {
    func destructiveControlTint() -> some View {
        modifier(DestructiveControlTint())
    }
}
