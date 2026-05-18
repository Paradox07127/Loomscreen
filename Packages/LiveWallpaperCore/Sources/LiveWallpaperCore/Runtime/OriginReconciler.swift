import Foundation

/// Event funneled through `OriginReconciler.reconcile(_:event:)` so the
/// reconciler can decide whether (and how) `ScreenConfiguration.wpeOrigin`
/// should be cleared or preserved.
///
/// Replaces the previous `ScreenConfiguration.reconcileWPEOrigin()` instance
/// method so the reconciliation policy can be injected (Lite vs. Pro) instead
/// of hard-coded in the model layer.
public enum OriginReconciliationEvent: Sendable {
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
public protocol OriginReconciler: Sendable {
    func reconcile(_ configuration: inout ScreenConfiguration, event: OriginReconciliationEvent)
}

/// No-op reconciler that only drops the origin when the persisted resource
/// location was explicitly marked `.unsupported`. Used by Lite, where the
/// full bookmark-matching pipeline is intentionally absent.
public struct PreservingOriginReconciler: OriginReconciler {
    public init() {}

    public func reconcile(_ configuration: inout ScreenConfiguration, event: OriginReconciliationEvent) {
        guard let origin = configuration.wpeOrigin else { return }
        if origin.resourceLocation == .unsupported {
            configuration.wpeOrigin = nil
        }
        _ = event
    }
}
