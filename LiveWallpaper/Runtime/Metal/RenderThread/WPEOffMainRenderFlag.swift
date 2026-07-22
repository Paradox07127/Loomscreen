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
/// The "Multithreaded rendering" setting writes this default-on key; `false`
/// selects main-thread rendering:
///   defaults write com.livewallpaper loomscreen.wallpapers.offMainRender.v1 -bool false
enum WPEOffMainRenderFlag {
    static let defaultsKey = "loomscreen.wallpapers.offMainRender.v1"

    /// Read once per display-actor construction. Absent ⇒ true (render-thread).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// Maps the preference through one fail-consistent construction path.
    static var backing: WPEDisplayRenderActor.Backing {
        isEnabled ? .renderThread : .main
    }
}
