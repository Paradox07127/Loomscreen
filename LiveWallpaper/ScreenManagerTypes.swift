import SwiftUI
import Combine
import Observation

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
///
/// `markWallpaperSessionStateChanged()` and `notifyWallpaperSessionChanged()`
/// used to drive three independent observable mutations on `ScreenManager`
/// (version bump + summary-cache rebuild + Combine subject send), forcing
/// SwiftUI consumers to re-evaluate three times per session change. Folding
/// them into one `Equatable` struct lets us commit the new state in a single
/// observable assignment: views invalidate at most once, and the equality
/// guard skips the assignment entirely when nothing actually changed.
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
    /// SKU-driven feature toggles. The Lite app target injects
    /// `FeatureCatalog(capabilities: .lite)`; everything else defaults to
    /// the full Pro catalogue so legacy entry points keep current behaviour.
    var featureCatalog: FeatureCatalog = FeatureCatalog(capabilities: .pro)
    /// Strategy used to keep `ScreenConfiguration.wpeOrigin` in sync with
    /// the active wallpaper. Defaults to the full Pro behaviour so the
    /// monolithic app retains its current bookmark-matching semantics; Lite
    /// will swap in `PreservingOriginReconciler` once Phase 4 splits ProWPE.
    #if LITE_BUILD
    var originReconciler: any OriginReconciler = PreservingOriginReconciler()
    #else
    var originReconciler: any OriginReconciler = WPEOriginReconciler()
    #endif

    // Reference-typed protocol fields are not synthesizable for Equatable.
    // Compare only the value-typed boolean configuration; injected dependencies
    // are test-time concerns and equality is irrelevant for them.
    static func == (lhs: ScreenManagerStartupOptions, rhs: ScreenManagerStartupOptions) -> Bool {
        lhs.restoreSavedWallpapers == rhs.restoreSavedWallpapers
            && lhs.startAutomation == rhs.startAutomation
            && lhs.featureCatalog == rhs.featureCatalog
    }
}

/// The activity assertion used while at least one wallpaper is actively
/// drawing. `userInitiatedAllowingIdleSystemSleep` keeps an LSUIElement app out
/// of App Nap without adding the idle-system-sleep prevention bit carried by
/// `.userInitiated`.
enum WallpaperRenderingActivityPolicy {
    static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
}
