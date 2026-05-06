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
        static let minWidth: CGFloat = 280
        static let idealWidth: CGFloat = 320
        static let maxWidth: CGFloat = 480
        static let horizontalPadding: CGFloat = Spacing.md
        static let verticalPadding: CGFloat = Spacing.lg
    }

    enum PreviewArea {
        static let minWidth: CGFloat = 480
    }

    enum Card {
        static let strokeOpacity: Double = 0.06
        static let strokeWidth: CGFloat = 0.5
        static let shadowRadius: CGFloat = 12
        static let shadowOpacity: Double = 0.18
        static let shadowYOffset: CGFloat = 4
    }
}
