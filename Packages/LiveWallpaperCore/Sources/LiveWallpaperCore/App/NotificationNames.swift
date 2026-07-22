import Foundation

// MARK: - Centralized Notification Names

extension Notification.Name {
    public static let screensRefreshed = Notification.Name("ScreensRefreshed")

    public static let selectScreenInSettings = Notification.Name("SelectScreenInSettings")

    public static let openGeneralSettings = Notification.Name("OpenGeneralSettings")

    /// Requests onboarding presentation without relying on the wrapped SwiftUI application delegate.
    public static let showOnboarding = Notification.Name("ShowOnboarding")

    /// Announces a persisted configuration change; `userInfo["screenID"]` identifies the display.
    public static let wallpaperConfigurationDidChange = Notification.Name("WallpaperConfigurationDidChange")

    /// Announces a WPE import result with `screenID` and original `type` in `userInfo`.
    public static let wpeImportDidComplete = Notification.Name("WPEImportDidComplete")

    /// The recent Wallpaper Engine import history (LRU) was mutated.
    /// Listeners — including the Scene tab UI — should reload from
    /// `SettingsManager.shared.loadGlobalSettings().recentWPEImports`.
    public static let wpeHistoryDidChange = Notification.Name("WPEHistoryDidChange")

    /// Requests an Add Wallpaper picker from the main window; `userInfo["kind"]` identifies the source type.
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

    /// Announces a developer-mode change to live web views and app navigation.
    public static let developerModeDidChange = Notification.Name("DeveloperModeDidChange")

    /// Requests navigation to the Workshop pane and any pending deep-link target.
    public static let openWorkshopPane = Notification.Name("OpenWorkshopPane")

    /// Request the main window to navigate to the Apple Aerials library (e.g.
    /// the onboarding "Apple Aerials" card on Lite / MAS Pro).
    public static let openAppleAerials = Notification.Name("OpenAppleAerials")

    /// `SMAppService.register/unregister` produced an outcome that needs
    /// user-visible follow-up (approval pending, app not in /Applications/,
    /// or thrown error). `userInfo["reason"]: LoginItemFailure`.
    public static let loginItemRegistrationDidFail = Notification.Name("LoginItemRegistrationDidFail")
}
