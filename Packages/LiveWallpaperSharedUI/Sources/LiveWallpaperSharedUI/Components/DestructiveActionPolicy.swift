import SwiftUI

/// Unified destructive-action confirmation following macOS 26 Tahoe HIG:
/// destructive button on top, Cancel on bottom keeping default focus; subtitle
/// carries action target + side-effect + recovery path. Attach with
/// `.confirmDestructive($action)`.
public enum DestructiveAction: Identifiable, Equatable {
    case removePlaylistItem(isLast: Bool, displayName: String)
    case removeSceneHistory(sceneName: String)
    case deleteBookmark(bookmarkName: String)
    case removeScheduleSlot(slotLabel: String)
    case disableSchedule(slotCount: Int)
    case clearUnusedWallpapers(itemCount: Int, byteSize: String)
    case clearAllStorageCaches(byteSize: String)
    case clearSceneVideoCache(byteSize: String)
    case clearAllWPECache(projectCount: Int, byteSize: String)
    case removeWPECacheEntry(displayName: String)
    case applyConfigurationToAllDisplays(otherCount: Int)
    case clearCurrentWallpaper(displayName: String)
    case resetDisplaySettings(displayName: String)
    case disconnectAerialsLibrary
    #if DEBUG
    /// Storage tab's debug-only cleanup of test-run scratch dirs. Gated so a
    /// shipping build carries neither the case nor its strings.
    case clearTestTempArtifacts(itemCount: Int, formattedSize: String)
    #endif

    public var id: String {
        switch self {
        case .removePlaylistItem(let isLast, let name): return "removePlaylistItem-\(isLast)-\(name)"
        case .removeSceneHistory(let s): return "removeSceneHistory-\(s)"
        case .deleteBookmark(let n): return "deleteBookmark-\(n)"
        case .removeScheduleSlot(let l): return "removeScheduleSlot-\(l)"
        case .disableSchedule(let c): return "disableSchedule-\(c)"
        case .clearUnusedWallpapers(let i, let b): return "clearUnusedWallpapers-\(i)-\(b)"
        case .clearAllStorageCaches(let b): return "clearAllStorageCaches-\(b)"
        case .clearSceneVideoCache(let b): return "clearSceneVideoCache-\(b)"
        case .clearAllWPECache(let c, let b): return "clearAllWPECache-\(c)-\(b)"
        case .removeWPECacheEntry(let n): return "removeWPECacheEntry-\(n)"
        case .applyConfigurationToAllDisplays(let c): return "applyConfigurationToAllDisplays-\(c)"
        case .clearCurrentWallpaper(let n): return "clearCurrentWallpaper-\(n)"
        case .resetDisplaySettings(let n): return "resetDisplaySettings-\(n)"
        case .disconnectAerialsLibrary: return "disconnectAerialsLibrary"
        #if DEBUG
        case .clearTestTempArtifacts(let i, let b): return "clearTestTempArtifacts-\(i)-\(b)"
        #endif
        }
    }

    public var title: LocalizedStringKey {
        switch self {
        case .removePlaylistItem(let isLast, _):
            return isLast ? "Remove the last playlist item?" : "Remove this playlist item?"
        case .removeSceneHistory:        return "Remove this scene from history?"
        case .deleteBookmark:            return "Delete this bookmark?"
        case .removeScheduleSlot:        return "Remove this schedule slot?"
        case .disableSchedule:           return "Disable schedule?"
        case .clearUnusedWallpapers:     return "Clear unused wallpapers?"
        case .clearAllStorageCaches:      return "Clear all storage caches?"
        case .clearSceneVideoCache:       return "Clear scene video texture cache?"
        case .clearAllWPECache:          return "Clear all cached scene projects?"
        case .removeWPECacheEntry:       return "Remove this cache entry?"
        case .applyConfigurationToAllDisplays: return "Apply this wallpaper to every other display?"
        case .clearCurrentWallpaper:     return "Clear current wallpaper?"
        case .resetDisplaySettings:      return "Reset this display's settings?"
        case .disconnectAerialsLibrary:  return "Disconnect Apple Aerials library?"
        #if DEBUG
        case .clearTestTempArtifacts:    return "Delete leftover test artifacts?"
        #endif
        }
    }

    public var message: String {
        switch self {
        case .removePlaylistItem(let isLast, let displayName):
            return isLast
                ? "This is the only wallpaper in the playlist. Removing it will clear the wallpaper on \(displayName)."
                : "The item will be removed from the playlist. Other displays using this video keep their copy."
        case .removeSceneHistory(let sceneName):
            return "\(sceneName) won't appear in your recent history anymore. The local cache is kept."
        case .deleteBookmark(let name):
            return "'\(name)' will be removed from your library. Displays using this bookmark fall back to their saved wallpaper."
        case .removeScheduleSlot(let slotLabel):
            return "The \(slotLabel) slot will be removed. Wallpapers outside this window keep their schedules."
        case .disableSchedule(let count):
            return "All \(count) time-based wallpaper rules will be cleared. The current wallpaper stays applied."
        case .clearUnusedWallpapers(let itemCount, let byteSize):
            return "Removes \(itemCount) items · \(byteSize) not displayed for more than 30 days. Currently-applied and pinned wallpapers are untouched."
        case .clearAllStorageCaches(let byteSize):
            return "Removes \(byteSize) of reclaimable cache files. Active wallpapers keep their source assignments and rebuild cached files when needed."
        case .clearSceneVideoCache(let byteSize):
            return "Deletes \(byteSize) of extracted scene video files. Scenes re-extract the video textures the next time they render."
        case .clearAllWPECache(let count, let byteSize):
            return "Removes \(count) legacy extracted project\(count == 1 ? "" : "s") · \(byteSize). Original source folders are untouched; wallpapers whose source is still available read in place from it instead."
        case .removeWPECacheEntry(let displayName):
            return "'\(displayName)' will read its assets directly from the source folder next time you apply it (if still available). The history entry and original source folder stay untouched."
        case .applyConfigurationToAllDisplays(let count):
            return "This replaces the wallpaper on \(count) other display\(count == 1 ? "" : "s") with the same content and settings as this one."
        case .clearCurrentWallpaper(let displayName):
            return "Only removes the current wallpaper from \(displayName). Source files, bookmarks, and library items are not deleted."
        case .resetDisplaySettings(let displayName):
            return "Restores playback, color, particle, audio, and layout settings on \(displayName) to defaults. The wallpaper itself, playlist bookmarks, and library items stay."
        case .disconnectAerialsLibrary:
            return "LiveWallpaper will release its read access to the local Apple Aerials folder. Existing aerial wallpapers stay applied; you'll need to reconnect to browse the library again."
        #if DEBUG
        case .clearTestTempArtifacts(let itemCount, let formattedSize):
            return "Deletes \(itemCount) scratch item\(itemCount == 1 ? "" : "s") · \(formattedSize) created by test runs in the container's tmp folder. Nothing else reads them."
        #endif
        }
    }

    public var destructiveButtonTitle: LocalizedStringKey {
        switch self {
        case .removePlaylistItem(let isLast, _):
            return isLast ? "Remove & Clear" : "Remove"
        case .removeSceneHistory:        return "Remove"
        case .deleteBookmark:            return "Delete"
        case .removeScheduleSlot:        return "Remove Slot"
        case .disableSchedule:           return "Disable Schedule"
        case .clearUnusedWallpapers(let itemCount, _): return "Clear \(itemCount) Items"
        case .clearAllStorageCaches:      return "Clear All Caches"
        case .clearSceneVideoCache:       return "Clear Video Cache"
        case .clearAllWPECache:          return "Clear All"
        case .removeWPECacheEntry:       return "Remove"
        case .applyConfigurationToAllDisplays: return "Apply to All Displays"
        case .clearCurrentWallpaper:     return "Clear Wallpaper"
        case .resetDisplaySettings:      return "Reset Settings"
        case .disconnectAerialsLibrary:  return "Disconnect"
        #if DEBUG
        case .clearTestTempArtifacts(let itemCount, _): return "Delete \(itemCount) Items"
        #endif
        }
    }
}

public struct PendingDestructive: Identifiable {
    public let id = UUID()
    public let action: DestructiveAction
    public let perform: () -> Void

    public init(_ action: DestructiveAction, perform: @escaping () -> Void) {
        self.action = action
        self.perform = perform
    }
}

extension View {
    public func confirmDestructive(_ pending: Binding<PendingDestructive?>) -> some View {
        modifier(DestructiveConfirmationModifier(pending: pending))
    }
}

private struct DestructiveConfirmationModifier: ViewModifier {
    @Binding var pending: PendingDestructive?

    func body(content: Content) -> some View {
        content.alert(
            pending?.action.title ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { current in
            Button(current.action.destructiveButtonTitle, role: .destructive) {
                let captured = current.perform
                pending = nil
                captured()
            }
            Button("Cancel", role: .cancel) {
                pending = nil
            }
        } message: { current in
            Text(current.action.message)
        }
    }
}
