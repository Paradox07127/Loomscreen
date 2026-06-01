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
    /// When the tile is the one whose detail inspector is open — draws an accent
    /// ring + soft accent glow so the grid↔inspector link is unmistakable.
    public let isSelected: Bool
    public let cornerRadius: CGFloat
    public let reduceMotion: Bool

    public init(
        isHovering: Bool,
        isSelected: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Corner.lg,
        reduceMotion: Bool = false
    ) {
        self.isHovering = isHovering
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
        self.reduceMotion = reduceMotion
    }

    public func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(DesignTokens.Card.strokeOpacity),
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
    /// Apply the shared gallery-tile chrome (corner clip + static stroke +
    /// resting/hover shadow + 1.02× lift). Pass `isSelected` to mark the tile
    /// whose detail inspector is open (accent ring + glow).
    public func galleryTileChrome(
        isHovering: Bool,
        isSelected: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Corner.lg,
        reduceMotion: Bool = false
    ) -> some View {
        modifier(GalleryTileChrome(
            isHovering: isHovering,
            isSelected: isSelected,
            cornerRadius: cornerRadius,
            reduceMotion: reduceMotion
        ))
    }
}
