import SwiftUI

/// Centralised design tokens for spacing, corners, and visual metrics.
/// Use these instead of inline magic numbers when building new UI.
/// Existing call sites may migrate incrementally.
enum DesignTokens {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Corner {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
    }

    enum Inspector {
        static let minWidth: CGFloat = 268
        static let idealWidth: CGFloat = 292
        static let maxWidth: CGFloat = 340
        static let defaultWidth: CGFloat = idealWidth
        static let horizontalPadding: CGFloat = Spacing.md
        static let verticalPadding: CGFloat = Spacing.lg
    }

    enum PreviewArea {
        static let minWidth: CGFloat = 480
    }

    enum Sidebar {
        static let width: CGFloat = 210
        static let maxWidth: CGFloat = width * 1.15
        static let sectionHeaderSpacing: CGFloat = 6
        static let sectionHeaderBottomPadding: CGFloat = 2
        static let displayHeaderBottomPadding: CGFloat = 6
    }

    enum DetailHeader {
        static let horizontalPadding: CGFloat = Spacing.xl
        static let verticalPadding: CGFloat = 14
        static let contentSpacing: CGFloat = 14
        static let iconSize: CGFloat = 44
        static let iconSymbolSize: CGFloat = 18
        static let titleSize: CGFloat = 18
        static let textSpacing: CGFloat = 2
        static let metadataSpacing: CGFloat = 8
    }

    enum GuidedLibrary {
        static let outerPadding: CGFloat = 40
        static let topSpacerHeight: CGFloat = 24
        static let iconSize: CGFloat = 48
        static let titleSize: CGFloat = 18
        static let messageSize: CGFloat = 13
        static let featureWidth: CGFloat = 380
        static let messageWidth: CGFloat = 360
    }

    enum Settings {
        static let formHorizontalMargin: CGFloat = 18
        static let formVerticalMargin: CGFloat = 12
        static let actionGridSpacing: CGFloat = 10
    }

    enum Card {
        static let strokeOpacity: Double = 0.06
        static let strokeWidth: CGFloat = 0.5
        static let shadowRadius: CGFloat = 12
        static let shadowOpacity: Double = 0.18
        static let shadowYOffset: CGFloat = 4
    }

    /// Returns the supplied animation when motion is allowed, otherwise nil so
    /// the change applies instantly. Pairs with `@Environment(\.accessibilityReduceMotion)`.
    static func motion(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}
