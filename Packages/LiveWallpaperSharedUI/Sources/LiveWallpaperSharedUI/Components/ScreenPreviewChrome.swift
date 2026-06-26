import SwiftUI

public extension View {
    /// Chrome for inspector-side preview cards (video + HTML). Placeholder
    /// states (`stroke: true`) typically pair with `shadow: false` to preserve
    /// the flat-card visual rhythm.
    func screenPreviewChrome(stroke: Bool = false, shadow: Bool = true) -> some View {
        modifier(_ScreenPreviewChrome(stroke: stroke, shadow: shadow))
    }
}

private struct _ScreenPreviewChrome: ViewModifier {
    let stroke: Bool
    let shadow: Bool

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(
                color: shadow ? .black.opacity(0.15) : .clear,
                radius: shadow ? 10 : 0,
                x: 0,
                y: shadow ? 4 : 0
            )
            .overlay {
                if stroke {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(.separatorColor), lineWidth: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
