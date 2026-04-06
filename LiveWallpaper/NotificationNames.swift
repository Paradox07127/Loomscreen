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
}
