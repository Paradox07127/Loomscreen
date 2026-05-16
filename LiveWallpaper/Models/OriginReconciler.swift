import Foundation

/// Event funneled through `OriginReconciler.reconcile(_:event:)` so the
/// reconciler can decide whether (and how) `ScreenConfiguration.wpeOrigin`
/// should be cleared or preserved.
///
/// Replaces the previous `ScreenConfiguration.reconcileWPEOrigin()` instance
/// method so the reconciliation policy can be injected (Lite vs. Pro) instead
/// of hard-coded in the model layer.
enum OriginReconciliationEvent: Sendable {
    /// Configuration was just loaded from disk. No mutation should occur —
    /// any persisted origin is treated as authoritative.
    case loaded
    /// User replaced the active wallpaper via the standard pickers
    /// (`setVideo`, `setHTMLWallpaper`, `setShaderWallpaper`). The previous
    /// `WallpaperContent` is supplied for reconcilers that want to short-
    /// circuit no-op transitions.
    case userReplacedActiveWallpaper(previous: WallpaperContent?)
    /// Active bookmark was refreshed (re-resolved) without changing identity;
    /// reconcilers should not drop the origin on this event.
    case refreshedBookmark(Data)
}

/// Pluggable strategy for keeping `ScreenConfiguration.wpeOrigin` consistent
/// with the active wallpaper content. Lite installs `PreservingOriginReconciler`
/// (zero WPE dependencies); Pro installs `WPEOriginReconciler` (full
/// bookmark/path matching via `WPEOrigin+Behavior`).
protocol OriginReconciler: Sendable {
    func reconcile(_ configuration: inout ScreenConfiguration, event: OriginReconciliationEvent)
}

/// No-op reconciler that only drops the origin when the persisted resource
/// location was explicitly marked `.unsupported`. Used by Lite, where the
/// full bookmark-matching pipeline is intentionally absent.
struct PreservingOriginReconciler: OriginReconciler {
    func reconcile(_ configuration: inout ScreenConfiguration, event: OriginReconciliationEvent) {
        guard let origin = configuration.wpeOrigin else { return }
        if origin.resourceLocation == .unsupported {
            configuration.wpeOrigin = nil
        }
        // Lite never owns WPEPathSafety — preserve origin metadata as
        // opaque round-trip payload so a future Pro launch can still drive
        // the WPE badge / fallback card from the persisted record.
        _ = event
    }
}

/// Pro reconciler — replays the previous `ScreenConfiguration.reconcileWPEOrigin()`
/// behaviour using bookmark matching from `WPEOrigin+Behavior`.
///
/// This file currently sits next to the schema (Phase 0); Phase 4 moves it
/// to the ProWPE package alongside the behaviour extension. Lite must not
/// transitively pull this type in once the module split lands.
struct WPEOriginReconciler: OriginReconciler {
    func reconcile(_ configuration: inout ScreenConfiguration, event: OriginReconciliationEvent) {
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
        case .video(let bookmarkData):
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
            // Shader switches are transient — preserve origin so a switch
            // back to Video/HTML restores the badge.
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
