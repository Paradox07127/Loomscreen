import SwiftUI
import Combine
import LiveWallpaperCore
import Observation
#if !LITE_BUILD
import LiveWallpaperProWPE
#endif

struct WallpaperSessionSummaryCache: Equatable {
    private var summariesByScreenID: [CGDirectDisplayID: WallpaperSessionSummary] = [:]

    init() {}

    init(entries: [(CGDirectDisplayID, WallpaperSessionSummary)]) {
        replace(with: entries)
    }

    mutating func replace(with entries: [(CGDirectDisplayID, WallpaperSessionSummary)]) {
        summariesByScreenID = Dictionary(uniqueKeysWithValues: entries)
    }

    func summary(
        for screenID: CGDirectDisplayID,
        fallback: @autoclosure () -> WallpaperSessionSummary
    ) -> WallpaperSessionSummary {
        summariesByScreenID[screenID] ?? fallback()
    }
}

/// Equatable snapshot of the derived wallpaper-session state.
struct WallpaperSessionState: Equatable {
    var version: UInt64 = 0
    var summaryCache: WallpaperSessionSummaryCache = WallpaperSessionSummaryCache()
    var isAnyPlaying: Bool = false
}

struct ScreenManagerStartupOptions: Equatable {
    var restoreSavedWallpapers: Bool = true
    var startAutomation: Bool = true
    var powerMonitor: (any PowerMonitoring)? = nil
    var fullScreenDetector: (any FullScreenDetecting)? = nil
    var playableVideoLoader: (any PlayableVideoLoading)? = nil
    var displayRegistry: (any DisplayRegistering)? = nil
    /// Tests/previews remain inert unless they explicitly inject a watcher. The
    /// production app startup plan supplies the single app-lifetime authority.
    var memoryPressureWatcher: any MemoryPressureWatching = InactiveMemoryPressureWatcher.shared
    /// SKU-driven feature toggles. Every production, test, and preview caller
    /// must explicitly choose Lite, Pro, or the fail-closed unconfigured state.
    var featureCatalog: FeatureCatalog
    #if LITE_BUILD
    var originReconciler: any OriginReconciler = PreservingOriginReconciler()
    #else
    var originReconciler: any OriginReconciler = WPEOriginReconciler()
    #endif

    static func == (lhs: ScreenManagerStartupOptions, rhs: ScreenManagerStartupOptions) -> Bool {
        lhs.restoreSavedWallpapers == rhs.restoreSavedWallpapers
            && lhs.startAutomation == rhs.startAutomation
            && lhs.featureCatalog == rhs.featureCatalog
    }
}

/// The activity assertion used while at least one wallpaper is actively drawing.
enum WallpaperRenderingActivityPolicy {
    static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
}
