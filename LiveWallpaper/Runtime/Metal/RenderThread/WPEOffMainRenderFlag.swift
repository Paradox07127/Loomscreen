import Foundation

/// Decides which thread each display's `WPEDisplayRenderActor` is backed by.
///
/// `true` (default) = a dedicated `WPERenderThread` per display, moving
/// per-display frame work off the main actor. `false` = the actor's isolation
/// runs on the main run loop, so the whole per-display render path executes on
/// the main thread — through the *identical* actor code path the `true` case
/// uses. The only variable between the two modes is the backing thread; nothing
/// else in the frame path branches on it.
///
/// Default-on (migration proven). The "Multithreaded rendering" setting toggle
/// writes this key; writing `false` is the rollback to main-thread rendering:
///   defaults write com.livewallpaper loomscreen.wallpapers.offMainRender.v1 -bool false
enum WPEOffMainRenderFlag {
    static let defaultsKey = "loomscreen.wallpapers.offMainRender.v1"

    /// Read once per display-actor construction. Absent ⇒ true (render-thread).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The backing the flag selects. Kept here so construction sites read the
    /// flag through one funnel instead of re-deriving the mapping.
    ///
    /// M2c1b-3c: the capability gate is lifted. The renderer now lives entirely
    /// inside `WPEDisplayRenderActor`'s isolation — the frame path, the async
    /// surfaces (load / reload / property-patch / static-texture reload) and the
    /// deferred audio/video tails all execute on the actor, so a background
    /// backing no longer races on-main state. `isEnabled` therefore reaches the
    /// backing directly. Default-on ⇒ `.renderThread`: each display owns a
    /// dedicated render thread. Writing the key `false` rolls back to `.main`.
    static var backing: WPEDisplayRenderActor.Backing {
        isEnabled ? .renderThread : .main
    }
}
