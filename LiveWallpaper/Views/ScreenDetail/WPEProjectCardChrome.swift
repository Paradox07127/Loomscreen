#if !LITE_BUILD
import SwiftUI

extension View {
    func wpeProjectCardChrome(isHovering: Bool, reduceMotion: Bool = false) -> some View {
        modifier(WPEProjectCardChrome(isHovering: isHovering, reduceMotion: reduceMotion))
    }
}

private struct WPEProjectCardChrome: ViewModifier {
    let isHovering: Bool
    let reduceMotion: Bool

    private static let cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .frame(
                minWidth: 160,
                idealWidth: 188,
                maxWidth: 240,
                minHeight: 240,
                idealHeight: 268,
                maxHeight: 320
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .adaptiveGlassSurface(.roundedRectangle(Self.cornerRadius), interactive: true)
            .scaleEffect(reduceMotion ? 1.0 : (isHovering ? 1.02 : 1.0))
            .shadow(
                color: Color.black.opacity(isHovering ? 0.18 : 0.06),
                radius: isHovering ? 8 : 4,
                y: isHovering ? 4 : 2
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8),
                value: isHovering
            )
    }
}
#endif
