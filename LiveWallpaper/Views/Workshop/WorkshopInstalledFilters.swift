#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Library type kinds for the chip row. No `.all` case — all-or-none selected
/// means "all". `.unsupported` collects the project types macOS can't run.
enum WPELibraryTypeKind: String, CaseIterable, Identifiable {
    case video, web, scene, unsupported

    var id: Self { self }

    var title: String {
        switch self {
        case .video: return WPEType.video.localizedDisplayName
        case .web: return WPEType.web.localizedDisplayName
        case .scene: return WPEType.scene.localizedDisplayName
        case .unsupported: return String(localized: "Unsupported", comment: "Workshop library type filter.")
        }
    }

    func matches(_ entry: WPEHistoryEntry) -> Bool {
        switch self {
        case .video: return entry.origin.originalType == .video
        case .web: return entry.origin.originalType == .web
        case .scene: return entry.origin.originalType == .scene
        case .unsupported: return entry.origin.originalType == .application || entry.origin.originalType == .unknown
        }
    }
}

/// Origin filter. Keys off the workshop ID because we don't record "SteamCMD
/// download vs manual import", so we can only tell real Workshop ID vs local.
enum InstalledSource: String, CaseIterable, Identifiable {
    case steamWorkshop, local

    var id: Self { self }

    var title: String {
        switch self {
        case .steamWorkshop: return String(localized: "Steam Workshop", comment: "Installed library origin filter: items with a real Steam Workshop ID.")
        case .local: return String(localized: "Local", comment: "Installed library origin filter: imported, no Steam Workshop ID.")
        }
    }

    func matches(_ entry: WPEHistoryEntry) -> Bool {
        let isSteam = UInt64(entry.origin.workshopID) != nil
        return self == .steamWorkshop ? isSteam : !isSteam
    }
}

/// Storage filter: app-managed cache copy (the usual shape for SteamCMD-
/// downloaded scenes) vs a link to the user's own folder (manual imports +
/// unpackaged downloads).
enum InstalledStorageKind: String, CaseIterable, Identifiable {
    case managed, linked

    var id: Self { self }

    var title: String {
        switch self {
        case .managed: return String(localized: "App copy", comment: "Installed library storage filter: extracted into the app's managed cache.")
        case .linked: return String(localized: "Linked folder", comment: "Installed library storage filter: links to the user's own folder.")
        }
    }

    func matches(_ entry: WPEHistoryEntry) -> Bool {
        let managed = entry.origin.resourceLocation == .cache
        return self == .managed ? managed : !managed
    }
}

enum WPELibrarySortOrder: String, CaseIterable, Identifiable {
    case recommended, name, updateAvailable

    var id: Self { self }

    var title: String {
        switch self {
        case .recommended: return String(localized: "Recent", comment: "Workshop library sort order: most recently imported first.")
        case .name: return String(localized: "Name", comment: "Workshop library sort order.")
        case .updateAvailable: return String(localized: "Needs Update", comment: "Workshop library sort order: update-available items first.")
        }
    }
}

enum WPEInstalledLibrarySorter {
    static func sorted(
        _ entries: [WPEHistoryEntry],
        by sortOrder: WPELibrarySortOrder,
        updatedWorkshopIDs: Set<String>
    ) -> [WPEHistoryEntry] {
        switch sortOrder {
        case .recommended:
            return entries
        case .name:
            return entries.sorted(by: compareByTitle)
        case .updateAvailable:
            return entries.sorted { lhs, rhs in
                let lhsNeedsUpdate = updatedWorkshopIDs.contains(lhs.origin.workshopID)
                let rhsNeedsUpdate = updatedWorkshopIDs.contains(rhs.origin.workshopID)
                if lhsNeedsUpdate != rhsNeedsUpdate {
                    return lhsNeedsUpdate
                }
                return compareByTitle(lhs, rhs)
            }
        }
    }

    private static func compareByTitle(_ lhs: WPEHistoryEntry, _ rhs: WPEHistoryEntry) -> Bool {
        let order = lhs.origin.title.localizedCaseInsensitiveCompare(rhs.origin.title)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.origin.workshopID.localizedCaseInsensitiveCompare(rhs.origin.workshopID) == .orderedAscending
    }
}

#endif
