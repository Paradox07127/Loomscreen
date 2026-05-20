import Foundation

// MARK: - Centralized Notification Names
// All custom notification names in one place to avoid raw string duplication.

extension Notification.Name {
    /// System memory usage exceeded the warning threshold.
    public static let systemMemoryWarning = Notification.Name("SystemMemoryWarning")

    /// The screen list was refreshed (connect/disconnect/parameter change).
    public static let screensRefreshed = Notification.Name("ScreensRefreshed")

    /// Request the settings UI to navigate to a specific screen.
    public static let selectScreenInSettings = Notification.Name("SelectScreenInSettings")

    /// Request the settings UI to navigate to the app preferences page.
    public static let openGeneralSettings = Notification.Name("OpenGeneralSettings")

    /// A screen's persisted wallpaper configuration changed (saved or removed).
    /// `userInfo["screenID"]: CGDirectDisplayID` identifies which screen.
    /// Inspectors / detail views should reload their @State from the manager
    /// when the screenID matches the one they currently display.
    public static let wallpaperConfigurationDidChange = Notification.Name("WallpaperConfigurationDidChange")

    /// A Wallpaper Engine import finished (success or unsupported variant).
    /// `userInfo["screenID"]: CGDirectDisplayID` identifies the target screen.
    /// `userInfo["type"]: String` is the WPE original type rawValue
    /// (`"video"` / `"web"` / `"scene"` / `"application"` / `"unknown"`).
    public static let wpeImportDidComplete = Notification.Name("WPEImportDidComplete")

    /// The recent Wallpaper Engine import history (LRU) was mutated.
    /// Listeners — including the Scene tab UI — should reload from
    /// `SettingsManager.shared.loadGlobalSettings().recentWPEImports`.
    public static let wpeHistoryDidChange = Notification.Name("WPEHistoryDidChange")

    /// Status-bar requested the main window to launch the appropriate
    /// "Add Wallpaper" picker. The status bar can no longer host a modal
    /// `NSOpenPanel` reliably — focus loss puts the panel behind the menu
    /// bar overlay. `userInfo["kind"]: String` is one of "video" / "html-file"
    /// / "html-folder" / "html-url".
    public static let promptAddWallpaper = Notification.Name("PromptAddWallpaper")

    /// Workshop library root bookmark was set or cleared. Sidebar /
    /// onboarding watch this so their conditional Workshop entry refreshes
    /// without needing a manual reopen.
    public static let workshopLibraryRootBookmarkDidChange = Notification.Name("WorkshopLibraryRootBookmarkDidChange")

    /// Wallpaper Engine install-root bookmark was set or cleared. Runtime
    /// scenes use it to mount WPE's bundled framework assets, and the Scene
    /// section's onboarding banner watches it to dismiss itself once granted.
    public static let wpeEngineAssetsBookmarkDidChange = Notification.Name("WPEEngineAssetsBookmarkDidChange")

    /// `GlobalSettings.showInDock` changed. The app delegate listens so the
    /// activation policy switch happens immediately without a relaunch.
    public static let dockVisibilityDidChange = Notification.Name("DockVisibilityDidChange")

    /// User-configurable global shortcut bindings changed. The
    /// `GlobalShortcutManager` re-registers all hot keys on this signal.
    public static let globalShortcutsDidChange = Notification.Name("GlobalShortcutsDidChange")

    /// User changed the weather location preference (source / manual coord).
    /// `WeatherReactiveService` reacts by re-resolving its provider chain.
    public static let weatherLocationPreferenceDidChange = Notification.Name("WeatherLocationPreferenceDidChange")

    /// `GlobalSettings.videoDecoderPreference` changed. `WallpaperVideoPlayer`
    /// listens and re-applies the resolution / bitrate ceiling to any active
    /// `AVPlayerItem` on the next reconcile.
    public static let videoDecoderPreferenceDidChange = Notification.Name("VideoDecoderPreferenceDidChange")
}
