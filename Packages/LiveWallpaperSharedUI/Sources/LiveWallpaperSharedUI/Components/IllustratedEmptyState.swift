import SwiftUI

/// Standard illustrated empty state used across the app: icon + title + message
/// + up to two actions. Replaces inline empty/error placeholders that drifted
/// across `EmptyStateGuideView`, `WPEFallbackCard`, `ScreenDetailPlaceholderViews`,
/// `WorkshopGalleryView` and `WeatherLocationSettingsView`.
public struct IllustratedEmptyState: View {
    public let symbol: String
    public let title: LocalizedStringKey
    public let message: LocalizedStringKey
    public var symbolColor: Color = .secondary
    public var primary: ButtonAction? = nil
    public var secondary: ButtonAction? = nil
    public var variant: Variant = .standard

    public enum Variant {
        case standard
        /// Renders the dashed drop-target border permanently so the affordance
        /// is discoverable without dragging anything onto the area first.
        case dropTarget
        /// Compact (denser padding, smaller icon) for use inside inspector rows.
        case compact
    }

    public struct ButtonAction {
        public let title: LocalizedStringKey
        public let role: ButtonRole?
        public let action: () -> Void

        public init(_ title: LocalizedStringKey, role: ButtonRole? = nil, action: @escaping () -> Void) {
            self.title = title
            self.role = role
            self.action = action
        }
    }

    public init(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        symbolColor: Color = .secondary,
        primary: ButtonAction? = nil,
        secondary: ButtonAction? = nil,
        variant: Variant = .standard
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.symbolColor = symbolColor
        self.primary = primary
        self.secondary = secondary
        self.variant = variant
    }

    public var body: some View {
        VStack(spacing: spacing) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)

            VStack(spacing: DesignTokens.Spacing.xxs) {
                Text(title)
                    .font(titleFont)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(messageFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360)

            if primary != nil || secondary != nil {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if let primary {
                        Button(role: primary.role, action: primary.action) {
                            Text(primary.title)
                        }
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                    }
                    if let secondary {
                        Button(role: secondary.role, action: secondary.action) {
                            Text(secondary.title)
                        }
                        .controlSize(.regular)
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, DesignTokens.Spacing.xs)
            }
        }
        .padding(verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if case .dropTarget = variant {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                            .fill(Color.accentColor.opacity(0.05))
                    )
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var iconSize: CGFloat {
        switch variant {
        case .standard, .dropTarget: return 44
        case .compact: return 28
        }
    }

    private var spacing: CGFloat {
        switch variant {
        case .standard, .dropTarget: return DesignTokens.Spacing.md
        case .compact: return DesignTokens.Spacing.sm
        }
    }

    private var verticalPadding: CGFloat {
        switch variant {
        case .standard, .dropTarget: return DesignTokens.Spacing.xl
        case .compact: return DesignTokens.Spacing.md
        }
    }

    private var titleFont: Font {
        switch variant {
        case .standard, .dropTarget: return .headline
        case .compact: return .subheadline
        }
    }

    private var messageFont: Font {
        switch variant {
        case .standard, .dropTarget: return .footnote
        case .compact: return .footnote
        }
    }
}
