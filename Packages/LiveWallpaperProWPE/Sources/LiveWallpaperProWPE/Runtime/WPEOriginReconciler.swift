import Foundation
import LiveWallpaperCore

/// Pro reconciler — replays the previous `ScreenConfiguration.reconcileWPEOrigin()`
/// behaviour using bookmark matching from `WPEOrigin+Behavior`.
///
/// Lives in LiveWallpaperProWPE because it depends on
/// `WPEOrigin.matchesBookmark(_:origin:)` which calls into `WPEPathSafety` —
/// both Pro-side. Lite installs `PreservingOriginReconciler` (from Core)
/// instead.
public struct WPEOriginReconciler: OriginReconciler {
    public init() {}

    public func reconcile(_ configuration: inout ScreenConfiguration, event: OriginReconciliationEvent) {
        guard let origin = configuration.wpeOrigin else { return }

        switch event {
        case .loaded, .refreshedBookmark:
            return
        case .userReplacedActiveWallpaper:
            break
        }

        guard origin.resourceLocation != .unsupported else {
            configuration.wpeOrigin = nil
            return
        }

        switch configuration.activeWallpaper {
        case .video(let bookmarkData, _):
            if !WPEOrigin.matchesBookmark(bookmarkData, origin: origin) {
                configuration.wpeOrigin = nil
            }
        case .html(let source, _):
            guard case .folder(let bookmarkData, _) = source,
                  WPEOrigin.matchesBookmark(bookmarkData, origin: origin) else {
                configuration.wpeOrigin = nil
                return
            }
        case .metalShader:
            return
        case .scene(let descriptor):
            guard origin.workshopID == descriptor.workshopID,
                  origin.cacheRelativePath == descriptor.cacheRelativePath else {
                configuration.wpeOrigin = nil
                return
            }
        }
    }
}
