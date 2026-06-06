import SwiftUI

/// Shared gallery-card chrome: optional Liquid-Glass backing, hairline stroke,
/// resting/hover shadow, a 1.02× hover lift, and a selected accent ring. Pass
/// `useGlass` for content cards; library tiles that supply their own backing
/// leave it off.
public struct GalleryTileChrome: ViewModifier {
    public let isHovering: Bool
    public let isSelected: Bool
    public let cornerRadius: CGFloat
    public let reduceMotion: Bool
    public let useGlass: Bool

    public init(
        isHovering: Bool,
        isSelected: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Corner.lg,
        reduceMotion: Bool = false,
        useGlass: Bool = false
    ) {
        self.isHovering = isHovering
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
        self.reduceMotion = reduceMotion
        self.useGlass = useGlass
    }

    public func body(content: Content) -> some View {
        content
            .background {
                if useGlass {
                    Color.clear.adaptiveGlassSurface(.roundedRectangle(cornerRadius), interactive: true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                // When glass is on it supplies its own hairline edge, so only the
                // accent selection ring is drawn here to avoid a double stroke.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor
                            : Color.primary.opacity(useGlass ? 0 : DesignTokens.Card.strokeOpacity),
                        lineWidth: isSelected ? 2.5 : DesignTokens.Card.strokeWidth
                    )
            }
            .shadow(
                color: isSelected
                    ? Color.accentColor.opacity(0.22)
                    : .black.opacity(isHovering
                                     ? DesignTokens.Card.shadowOpacity
                                     : DesignTokens.Card.restShadowOpacity),
                radius: isHovering || isSelected
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
            .animation(
                DesignTokens.motion(reduceMotion, .spring(response: 0.28, dampingFraction: 0.85)),
                value: isSelected
            )
    }
}

extension View {
    public func galleryTileChrome(
        isHovering: Bool,
        isSelected: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Corner.lg,
        reduceMotion: Bool = false,
        useGlass: Bool = false
    ) -> some View {
        modifier(GalleryTileChrome(
            isHovering: isHovering,
            isSelected: isSelected,
            cornerRadius: cornerRadius,
            reduceMotion: reduceMotion,
            useGlass: useGlass
        ))
    }
}
