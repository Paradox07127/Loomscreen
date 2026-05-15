import Foundation

// MARK: - Centralized Notification Names
// All custom notification names in one place to avoid raw string duplication.

extension Notification.Name {
    /// System memory usage exceeded the warning threshold.
    static let systemMemoryWarning = Notification.Name("SystemMemoryWarning")

    /// The screen list was refreshed (connect/disconnect/parameter change).
    static let screensRefreshed = Notification.Name("ScreensRefreshed")

    /// Request the settings UI to navigate to a specific screen.
    static let selectScreenInSettings = Notification.Name("SelectScreenInSettings")

    /// Request the settings UI to navigate to the app preferences page.
    static let openGeneralSettings = Notification.Name("OpenGeneralSettings")

    /// A video player completed one full loop of its current video.
    static let videoDidCompleteLoop = Notification.Name("VideoDidCompleteLoop")

    /// A screen's persisted wallpaper configuration changed (saved or removed).
    /// `userInfo["screenID"]: CGDirectDisplayID` identifies which screen.
    /// Inspectors / detail views should reload their @State from the manager
    /// when the screenID matches the one they currently display.
    static let wallpaperConfigurationDidChange = Notification.Name("WallpaperConfigurationDidChange")

    /// A Wallpaper Engine import finished (success or unsupported variant).
    /// `userInfo["screenID"]: CGDirectDisplayID` identifies the target screen.
    /// `userInfo["type"]: String` is the WPE original type rawValue
    /// (`"video"` / `"web"` / `"scene"` / `"application"` / `"unknown"`).
    static let wpeImportDidComplete = Notification.Name("WPEImportDidComplete")

    /// The recent Wallpaper Engine import history (LRU) was mutated.
    /// Listeners — including the Scene tab UI — should reload from
    /// `SettingsManager.shared.loadGlobalSettings().recentWPEImports`.
    static let wpeHistoryDidChange = Notification.Name("WPEHistoryDidChange")

    /// Status-bar requested the main window to launch the appropriate
    /// "Add Wallpaper" picker. The status bar can no longer host a modal
    /// `NSOpenPanel` reliably — focus loss puts the panel behind the menu
    /// bar overlay. `userInfo["kind"]: String` is one of "video" / "html-file"
    /// / "html-folder" / "html-url".
    static let promptAddWallpaper = Notification.Name("PromptAddWallpaper")

    /// Workshop library root bookmark was set or cleared. Sidebar /
    /// onboarding watch this so their conditional Workshop entry refreshes
    /// without needing a manual reopen.
    static let workshopLibraryRootBookmarkDidChange = Notification.Name("WorkshopLibraryRootBookmarkDidChange")

    /// Wallpaper Engine install-root bookmark was set or cleared. Runtime
    /// scenes use it to mount WPE's bundled framework assets, and the Scene
    /// section's onboarding banner watches it to dismiss itself once granted.
    static let wpeEngineAssetsBookmarkDidChange = Notification.Name("WPEEngineAssetsBookmarkDidChange")

    /// `GlobalSettings.showInDock` changed. The app delegate listens so the
    /// activation policy switch happens immediately without a relaunch.
    static let dockVisibilityDidChange = Notification.Name("DockVisibilityDidChange")

    /// User-configurable global shortcut bindings changed. The
    /// `GlobalShortcutManager` re-registers all hot keys on this signal.
    static let globalShortcutsDidChange = Notification.Name("GlobalShortcutsDidChange")

    /// User changed the weather location preference (source / manual coord).
    /// `WeatherReactiveService` reacts by re-resolving its provider chain.
    static let weatherLocationPreferenceDidChange = Notification.Name("WeatherLocationPreferenceDidChange")

    /// `GlobalSettings.menuBarDensity` changed. `MenuBarContent` listens so
    /// the menubar dropdown re-resolves its padding/spacing on the next show.
    static let menuBarDensityDidChange = Notification.Name("MenuBarDensityDidChange")
}
