import SwiftUI

/// Unified confirmation flow for destructive actions.
///
/// Replaces ad-hoc inline destruction (`onDelete`, `Button { delete() }`) with a
/// single Liquid Glass confirmation that follows macOS 26 Tahoe HIG:
/// - Destructive button on top, Cancel on bottom
/// - Cancel keeps default focus (Esc / ⌘. dismisses)
/// - Subtitle carries action target + side-effect + recovery path
///
/// Attach with `.confirmDestructive($action, perform:)` and trigger by writing
/// a `DestructiveAction` value into the binding.
public enum DestructiveAction: Identifiable, Equatable {
    case removePlaylistItem(isLast: Bool, displayName: String)
    case clearScene(sceneName: String, displayName: String)
    case removeSceneHistory(sceneName: String)
    case deleteBookmark(bookmarkName: String)
    case applyBookmarkToAll(bookmarkName: String, displayCount: Int)
    case removeScheduleSlot(slotLabel: String)
    case disableSchedule(slotCount: Int)
    case clearUnusedWallpapers(itemCount: Int, byteSize: String)
    case forgetWorkshopLibrary(path: String)
    case forgetEngineAssets(path: String)
    case removeHistoryEntry(name: String)
    case clearAllShortcuts
    case resetShortcut(commandName: String)
    case resetAllSettings
    case clearAllWPECache(projectCount: Int, byteSize: String)
    case removeWPECacheEntry(displayName: String)
    case applyConfigurationToAllDisplays(otherCount: Int)
    case clearCurrentWallpaper(displayName: String)
    case resetDisplaySettings(displayName: String)
    case disconnectAerialsLibrary

    public var id: String {
        switch self {
        case .removePlaylistItem(let isLast, let name): return "removePlaylistItem-\(isLast)-\(name)"
        case .clearScene(let s, let d): return "clearScene-\(s)-\(d)"
        case .removeSceneHistory(let s): return "removeSceneHistory-\(s)"
        case .deleteBookmark(let n): return "deleteBookmark-\(n)"
        case .applyBookmarkToAll(let n, let c): return "applyBookmarkToAll-\(n)-\(c)"
        case .removeScheduleSlot(let l): return "removeScheduleSlot-\(l)"
        case .disableSchedule(let c): return "disableSchedule-\(c)"
        case .clearUnusedWallpapers(let i, let b): return "clearUnusedWallpapers-\(i)-\(b)"
        case .forgetWorkshopLibrary(let p): return "forgetWorkshopLibrary-\(p)"
        case .forgetEngineAssets(let p): return "forgetEngineAssets-\(p)"
        case .removeHistoryEntry(let n): return "removeHistoryEntry-\(n)"
        case .clearAllShortcuts: return "clearAllShortcuts"
        case .resetShortcut(let n): return "resetShortcut-\(n)"
        case .resetAllSettings: return "resetAllSettings"
        case .clearAllWPECache(let c, let b): return "clearAllWPECache-\(c)-\(b)"
        case .removeWPECacheEntry(let n): return "removeWPECacheEntry-\(n)"
        case .applyConfigurationToAllDisplays(let c): return "applyConfigurationToAllDisplays-\(c)"
        case .clearCurrentWallpaper(let n): return "clearCurrentWallpaper-\(n)"
        case .resetDisplaySettings(let n): return "resetDisplaySettings-\(n)"
        case .disconnectAerialsLibrary: return "disconnectAerialsLibrary"
        }
    }

    public var title: LocalizedStringKey {
        switch self {
        case .removePlaylistItem(let isLast, _):
            return isLast ? "Remove the last playlist item?" : "Remove this playlist item?"
        case .clearScene:                return "Clear the Scene wallpaper?"
        case .removeSceneHistory:        return "Remove this scene from history?"
        case .deleteBookmark:            return "Delete this bookmark?"
        case .applyBookmarkToAll:        return "Apply to all displays?"
        case .removeScheduleSlot:        return "Remove this schedule slot?"
        case .disableSchedule:           return "Disable schedule?"
        case .clearUnusedWallpapers:     return "Clear unused wallpapers?"
        case .forgetWorkshopLibrary:     return "Forget scene library?"
        case .forgetEngineAssets:        return "Forget external scene-format install folder?"
        case .removeHistoryEntry:        return "Remove from history?"
        case .clearAllShortcuts:         return "Reset all keyboard shortcuts?"
        case .resetShortcut:             return "Reset this shortcut?"
        case .resetAllSettings:          return "Reset all settings?"
        case .clearAllWPECache:          return "Clear all cached scene projects?"
        case .removeWPECacheEntry:       return "Remove this cache entry?"
        case .applyConfigurationToAllDisplays: return "Apply this wallpaper to every other display?"
        case .clearCurrentWallpaper:     return "Clear current wallpaper?"
        case .resetDisplaySettings:      return "Reset this display's settings?"
        case .disconnectAerialsLibrary:  return "Disconnect Apple Aerials library?"
        }
    }

    public var message: String {
        switch self {
        case .removePlaylistItem(let isLast, let displayName):
            return isLast
                ? "This is the only wallpaper in the playlist. Removing it will clear the wallpaper on \(displayName)."
                : "The item will be removed from the playlist. Other displays using this video keep their copy."
        case .clearScene(let sceneName, let displayName):
            return "Removing \(sceneName) will return \(displayName) to its saved wallpaper. The scene cache stays on disk."
        case .removeSceneHistory(let sceneName):
            return "\(sceneName) won't appear in your recent history anymore. The local cache is kept."
        case .deleteBookmark(let name):
            return "'\(name)' will be removed from your library. Displays using this bookmark fall back to their saved wallpaper."
        case .applyBookmarkToAll(let name, let count):
            return "'\(name)' will replace the current wallpaper on \(count) displays. Existing assignments are saved and can be restored from history."
        case .removeScheduleSlot(let slotLabel):
            return "The \(slotLabel) slot will be removed. Wallpapers outside this window keep their schedules."
        case .disableSchedule(let count):
            return "All \(count) time-based wallpaper rules will be cleared. The current wallpaper stays applied."
        case .clearUnusedWallpapers(let itemCount, let byteSize):
            return "Removes \(itemCount) items · \(byteSize) not displayed for more than 30 days. Currently-applied and pinned wallpapers are untouched."
        case .forgetWorkshopLibrary(let path):
            return "The library at '\(path)' will be unlinked. Local scene caches are kept; you can re-link the folder later."
        case .forgetEngineAssets(let path):
            return "The external scene-format install folder at '\(path)' will be unlinked. Scenes that depend on shared engine framework files will fail to render until you grant access again."
        case .removeHistoryEntry(let name):
            return "'\(name)' will be removed from your recent items. The underlying file or scene is not deleted."
        case .clearAllShortcuts:
            return "All custom keyboard shortcuts revert to the LiveWallpaper defaults."
        case .resetShortcut(let commandName):
            return "The shortcut for '\(commandName)' returns to its default key combination."
        case .resetAllSettings:
            return "All preferences, screen configurations, playlists, schedules, and bookmarks return to their defaults. This cannot be undone."
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
        }
    }

    public var destructiveButtonTitle: LocalizedStringKey {
        switch self {
        case .removePlaylistItem(let isLast, _):
            return isLast ? "Remove & Clear" : "Remove"
        case .clearScene:                return "Clear Scene"
        case .removeSceneHistory:        return "Remove"
        case .deleteBookmark:            return "Delete"
        case .applyBookmarkToAll:        return "Apply to All"
        case .removeScheduleSlot:        return "Remove Slot"
        case .disableSchedule:           return "Disable Schedule"
        case .clearUnusedWallpapers(let itemCount, _): return "Clear \(itemCount) Items"
        case .forgetWorkshopLibrary:     return "Forget Library"
        case .forgetEngineAssets:        return "Forget Engine Folder"
        case .removeHistoryEntry:        return "Remove"
        case .clearAllShortcuts:         return "Reset All"
        case .resetShortcut:             return "Reset"
        case .resetAllSettings:          return "Reset All"
        case .clearAllWPECache:          return "Clear All"
        case .removeWPECacheEntry:       return "Remove"
        case .applyConfigurationToAllDisplays: return "Apply to All Displays"
        case .clearCurrentWallpaper:     return "Clear Wallpaper"
        case .resetDisplaySettings:      return "Reset Settings"
        case .disconnectAerialsLibrary:  return "Disconnect"
        }
    }
}

/// Bundles a `DestructiveAction` with the closure to invoke on confirmation.
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
    /// Presents the native macOS confirmation alert when `pending` becomes non-nil.
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
