import Foundation
import SwiftUI

/// Persistence keys for the menu-bar control center. Centralised so callers
/// across components share the same identifiers and so a future settings
/// surface can list every customisable knob.
enum MenuBarPreferenceKey {
    static let selectedScreenID = "MenuBar.SelectedScreenID"
    static let popoverMode = "MenuBar.PopoverMode"
    static let diagnosticsVisible = "MenuBar.Section.DiagnosticsVisible"
    static let effectsVisible = "MenuBar.Section.EffectsVisible"
    static let bookmarksVisible = "MenuBar.Section.BookmarksVisible"
    static let automationVisible = "MenuBar.Section.AutomationVisible"
    static let otherDisplaysVisible = "MenuBar.Section.OtherDisplaysVisible"
    static let pinnedBookmarksJSON = "MenuBar.PinnedBookmarkIDsJSON"
    static let dashboardExpanded = "MenuBar.DashboardExpanded"
    static let ramScope = "Dashboard.RAMScope"
}

enum MenuBarPopoverMode: String, CaseIterable, Identifiable {
    case compact
    case standard
    case expanded

    var id: String { rawValue }

    /// Total popover width. Standard matches the previous design at 320pt;
    /// compact trims the ancillary sections; expanded gives Effects + Bookmarks
    /// breathing room and reveals the OtherDisplays list when ≥3 screens.
    var width: CGFloat {
        switch self {
        case .compact: return 280
        case .standard: return 320
        case .expanded: return 360
        }
    }

    var displayLabel: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .expanded: return "Expanded"
        }
    }
}
