import SwiftUI
import AppKit

/// Centralised design tokens for spacing, corners, and visual metrics.
public enum DesignTokens {
    public enum Colors {
        // Surfaces — automatically adapt to light/dark and Increase Contrast.
        public static let pageBackground = Color(nsColor: .windowBackgroundColor)
        public static let surfaceRaised = Color(nsColor: .controlBackgroundColor)
        public static let surfaceSunken = Color(nsColor: .underPageBackgroundColor)

        public static let textPrimary = Color(nsColor: .labelColor)
        public static let textSecondary = Color(nsColor: .secondaryLabelColor)
        public static let textTertiary = Color(nsColor: .tertiaryLabelColor)

        public static let separator = Color(nsColor: .separatorColor)
        public static let accent = Color(nsColor: .controlAccentColor)

        /// Dark green for white-glyph "active / in-library" badges over bright
        /// artwork — system green is too light to clear WCAG AA there. Fixed RGB
        /// (not adaptive) on purpose; the badge sits on its own glass backing.
        public static let badgeActive = Color(red: 0.08, green: 0.35, blue: 0.15)

        public enum Status {
            public static let active = Color(nsColor: .systemGreen)
            public static let warning = Color(nsColor: .systemOrange)
            public static let caution = Color(nsColor: .systemYellow)
            public static let danger = Color(nsColor: .systemRed)
        }

        /// Ring-gauge palette (CPU/GPU/RAM/power dashboards). Clear, legible hues
        /// just slightly softer than `Status.*`; paired with a thin 3.5pt ring so
        /// the always-busy usage rings read calmly without going muddy/grey.
        public enum Gauge {
            public static let low = Color(red: 0.24, green: 0.72, blue: 0.40)
            public static let medium = Color(red: 0.95, green: 0.60, blue: 0.16)
            public static let high = Color(red: 0.90, green: 0.33, blue: 0.31)
        }
    }

    /// Prefer Dynamic Type styles so text auto-scales with accessibility
    /// settings; only `badge` is fixed-size because it floats in tight,
    /// fixed-geometry chips. Never inline `.font(.system(size:))` on text —
    /// standalone SF Symbol glyph sizing is the documented exemption
    /// (DESIGN.md hard rule 1).
    public enum Typography {
        public static let badge = Font.system(.caption2).weight(.semibold)

        public static let caption = Font.caption
        public static let captionEmphasized = Font.caption.weight(.semibold)

        public static let body = Font.body
        public static let bodyEmphasized = Font.body.weight(.semibold)

        /// A step above `bodyEmphasized` (also 13pt semibold) so hierarchy stays legible.
        public static let sectionTitle = Font.title3.weight(.semibold)

        public static let pageTitle = Font.title2

        public static let hero = Font.largeTitle

        /// Tabular digits so dense numeric columns stay compact and don't jitter.
        public static let metric = Font.caption.monospacedDigit()

        public static let code = Font.system(.body, design: .monospaced)

        /// Caption-scale `code` for dense technical text: log lines, paths, IDs.
        public static let codeCaption = Font.system(.caption, design: .monospaced)
    }

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
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
        public static let maxWidth: CGFloat = 392
        public static let defaultWidth: CGFloat = idealWidth
        public static let horizontalPadding: CGFloat = Spacing.md
        /// Shared geometry for every inspector "label … [slider][value]" row so
        /// sliders and their numeric readouts line up across all sections. The
        /// readout font (`Typography.metric`) is already monospaced, so call
        /// sites don't need a separate `.monospacedDigit()`.
        public static let sliderWidth: CGFloat = 96
        public static let sliderValueWidth: CGFloat = 40
        public static let sliderValueSpacing: CGFloat = 4
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

    public enum Sidebar {
        public static let width: CGFloat = 180
        public static let maxWidth: CGFloat = width * 1.2
        public static let sectionHeaderBottomPadding: CGFloat = 0
        /// Negative inset pulled above each sidebar section header to tighten the
        /// otherwise-airy default gap between sections (macOS has no public
        /// `listSectionSpacing`, so we claw it back on the header itself).
        public static let sectionHeaderTopPadding: CGFloat = -7
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
        // Search-field widths, trimmed twice from the original 220 / 280 / 360
        // (−25% then a further −20%) so the bar — and the narrow detail
        // inspector that reuses these tokens — stays legible at minimum width.
        public static let searchMinWidth: CGFloat = 132
        public static let searchIdealWidth: CGFloat = 168
        public static let searchMaxWidth: CGFloat = 216
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

    /// nil when Reduce Motion is on, so the change applies instantly.
    public static func motion(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}
