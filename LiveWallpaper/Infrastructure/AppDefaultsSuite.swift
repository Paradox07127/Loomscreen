import Foundation

extension UserDefaults {
    /// The app's `Taijia.LiveWallpaper` defaults domain. When the current process IS the app, its
    /// standard domain already maps to that bundle ID, so we return `.standard`: passing your own
    /// bundle identifier to `init(suiteName:)` is rejected by macOS with the
    /// `_NSUserDefaults_Log_Nonsensical_Suites` warning and yields no usable store. In a host
    /// process with a different bundle ID (a screensaver/agent embedding the renderer) we open the
    /// explicit suite so `defaults write Taijia.LiveWallpaper …` knobs are still honoured.
    static var appSuite: UserDefaults {
        let appBundleID = "Taijia.LiveWallpaper"
        if Bundle.main.bundleIdentifier == appBundleID { return .standard }
        return UserDefaults(suiteName: appBundleID) ?? .standard
    }
}
