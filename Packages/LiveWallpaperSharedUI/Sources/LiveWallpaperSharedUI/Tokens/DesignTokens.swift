import SwiftUI
import AppKit

/// Centralised design tokens for spacing, corners, and visual metrics.
/// Use these instead of inline magic numbers when building new UI.
/// Existing call sites may migrate incrementally.
public enum DesignTokens {
    public enum Colors {
        public static let pageBackground = Color(nsColor: .windowBackgroundColor)
    }

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Corner {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 10
        public static let lg: CGFloat = 14
        public static let xl: CGFloat = 18
    }

    public enum Inspector {
        public static let minWidth: CGFloat = 268
        public static let idealWidth: CGFloat = 292
        public static let maxWidth: CGFloat = 340
        public static let defaultWidth: CGFloat = idealWidth
        public static let horizontalPadding: CGFloat = Spacing.md
        public static let verticalPadding: CGFloat = Spacing.lg
        /// Horizontal padding floor when the inspector is dragged to its min width.
        /// Vertical padding stays constant — only horizontal compresses with width.
        public static let minHorizontalPadding: CGFloat = 9
        /// Linear interpolation: padding == horizontalPadding when width == maxWidth,
        /// floors at `minHorizontalPadding` when the user drags toward `minWidth`.
        public static func horizontalPadding(for width: CGFloat) -> CGFloat {
            let target = width * (horizontalPadding / maxWidth)
            return min(max(target, minHorizontalPadding), horizontalPadding)
        }
    }

    public enum PreviewArea {
        public static let minWidth: CGFloat = 480
    }

    public enum Sidebar {
        public static let width: CGFloat = 210
        public static let maxWidth: CGFloat = width * 1.15
        public static let sectionHeaderSpacing: CGFloat = 6
        public static let sectionHeaderBottomPadding: CGFloat = 2
        public static let displayHeaderBottomPadding: CGFloat = 6
    }

    public enum DetailHeader {
        public static let horizontalPadding: CGFloat = Spacing.xl
        public static let verticalPadding: CGFloat = 14
        public static let contentSpacing: CGFloat = 14
        public static let iconSize: CGFloat = 40
        public static let iconSymbolSize: CGFloat = 20
        public static let titleSize: CGFloat = 18
        public static let textSpacing: CGFloat = 2
        public static let metadataSpacing: CGFloat = 8
    }

    /// Detail-page secondary control row (library filter bar). Anchored under
    /// the DetailHeaderBar with the same horizontal alignment so the search
    /// capsule lines up with the header brand icon. Vertical padding stays
    /// tighter than the header so the two rows read as one composite hero.
    public enum LibraryFilterBar {
        public static let horizontalPadding: CGFloat = Spacing.xl
        public static let verticalPadding: CGFloat = 10
        public static let contentSpacing: CGFloat = 10
        // Search-field widths, ~25% shorter than the original 220 / 280 / 360 so
        // the bar leaves more room for chips / pickers on the same row.
        public static let searchMinWidth: CGFloat = 165
        public static let searchIdealWidth: CGFloat = 210
        public static let searchMaxWidth: CGFloat = 270
        public static let controlHeight: CGFloat = 28
    }

    /// Floor dimensions every sidebar-routed library page uses. Without this,
    /// macOS 26 NavigationSplitView occasionally squeezes the detail column,
    /// drives the sidebar list below its `navigationSplitViewColumnWidth`
    /// minimum, and drops the upper sections (Displays + Library) out of view.
    /// Workshop hit this first and pinned its own floor; promoting it here
    /// keeps Bookmarks / Apple Aerials behaving the same way.
    public enum LibraryPage {
        public static let minWidth: CGFloat = 760
        public static let minHeight: CGFloat = 540
    }

    public enum GuidedLibrary {
        public static let outerPadding: CGFloat = 40
        public static let topSpacerHeight: CGFloat = 24
        public static let iconSize: CGFloat = 48
        public static let titleSize: CGFloat = 18
        public static let messageSize: CGFloat = 13
        public static let featureWidth: CGFloat = 380
        public static let messageWidth: CGFloat = 360
    }

    public enum Settings {
        public static let formHorizontalMargin: CGFloat = 18
        public static let formVerticalMargin: CGFloat = 12
        public static let actionGridSpacing: CGFloat = 10
    }

    public enum Card {
        public static let strokeOpacity: Double = 0.06
        public static let strokeWidth: CGFloat = 0.5
        public static let shadowRadius: CGFloat = 12
        public static let shadowOpacity: Double = 0.18
        public static let shadowYOffset: CGFloat = 4

        /// Resting elevation values for gallery tiles — keep a faint always-on
        /// shadow so hover smoothly interpolates instead of popping from flat.
        /// Matches the macOS News / Photos Memories resting profile.
        public static let restShadowRadius: CGFloat = 3
        public static let restShadowOpacity: Double = 0.05
        public static let restShadowYOffset: CGFloat = 1
    }

    /// Returns the supplied animation when motion is allowed, otherwise nil so the change applies instantly.
    public static func motion(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}
