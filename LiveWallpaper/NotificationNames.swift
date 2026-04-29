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
}
