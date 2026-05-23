import SwiftUI

/// Visual chrome shared by 16:9 gallery tiles (Bookmarks, Aerials, future
/// libraries). Captures the macOS-native resting profile — static hairline
/// stroke, always-on soft shadow that smoothly elevates on hover, and a
/// gentle 1.02× lift — so each call site stops re-implementing the same
/// modifier stack.
///
/// Apply to the thumbnail container *after* its own clipShape / overlays
/// have settled; this modifier owns the outer clip + stroke + shadow +
/// scale so the call site only contributes the artwork.
public struct GalleryTileChrome: ViewModifier {
    public let isHovering: Bool
    public let cornerRadius: CGFloat
    public let reduceMotion: Bool

    public init(
        isHovering: Bool,
        cornerRadius: CGFloat = DesignTokens.Corner.lg,
        reduceMotion: Bool = false
    ) {
        self.isHovering = isHovering
        self.cornerRadius = cornerRadius
        self.reduceMotion = reduceMotion
    }

    public func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(DesignTokens.Card.strokeOpacity),
                        lineWidth: DesignTokens.Card.strokeWidth
                    )
            }
            .shadow(
                color: .black.opacity(isHovering
                                      ? DesignTokens.Card.shadowOpacity
                                      : DesignTokens.Card.restShadowOpacity),
                radius: isHovering
                    ? DesignTokens.Card.shadowRadius
                    : DesignTokens.Card.restShadowRadius,
                x: 0,
                y: isHovering
                    ? DesignTokens.Card.shadowYOffset
                    : DesignTokens.Card.restShadowYOffset
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(
                DesignTokens.motion(reduceMotion, .spring(response: 0.28, dampingFraction: 0.85)),
                value: isHovering
            )
    }
}

extension View {
    /// Apply the shared gallery-tile chrome (corner clip + static stroke +
    /// resting/hover shadow + 1.02× lift) to a thumbnail tile container.
    public func galleryTileChrome(
        isHovering: Bool,
        cornerRadius: CGFloat = DesignTokens.Corner.lg,
        reduceMotion: Bool = false
    ) -> some View {
        modifier(GalleryTileChrome(
            isHovering: isHovering,
            cornerRadius: cornerRadius,
            reduceMotion: reduceMotion
        ))
    }
}
