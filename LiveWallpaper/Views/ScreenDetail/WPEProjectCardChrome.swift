#if !LITE_BUILD
import SwiftUI

extension View {
    func wpeCardPreviewClip(cornerRadius: CGFloat = 16) -> some View {
        clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: cornerRadius,
                style: .continuous
            )
        )
    }

    func wpeProjectCardChrome(isHovering: Bool) -> some View {
        modifier(WPEProjectCardChrome(isHovering: isHovering))
    }
}

private struct WPEProjectCardChrome: ViewModifier {
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: 160, height: 240)
            .adaptiveGlassSurface(.roundedRectangle(16), interactive: true)
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .shadow(
                color: Color.black.opacity(isHovering ? 0.18 : 0.06),
                radius: isHovering ? 8 : 4,
                y: isHovering ? 4 : 2
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isHovering)
    }
}
#endif
