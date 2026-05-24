#if !LITE_BUILD
import Foundation

/// User-facing scene-renderer mode. `.automatic` defers the choice to
/// `WPESceneBackendRouter`, which inspects the scene at session-build time;
/// `.metal` and `.webGL` pin the renderer regardless of scene contents.
enum WPERuntimeSelection: String, Sendable, CaseIterable {
    case automatic = "auto"
    case metal
    case webGL = "webgl"

    /// Phase-11 string-valued default. Three valid values: `auto`, `metal`,
    /// `webgl`. Replaces the legacy boolean `WPEUseWebGLRuntime` key; the
    /// boolean is migrated lazily inside `current` if the new key is absent.
    static let defaultsKey = "WPERuntimeSelection"

    /// Original Phase-0 boolean toggle (`true` → WebGL, `false` → Metal).
    /// Read once when the new key is missing so existing DEBUG configurations
    /// don't silently flip after upgrade.
    static let legacyDefaultsKey = "WPEUseWebGLRuntime"

    /// User's chosen mode. May be `.automatic`; callers that need a
    /// concrete backend should pass the selection through
    /// `WPESceneBackendRouter.resolve(...)`.
    static var current: WPERuntimeSelection {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let selection = WPERuntimeSelection(rawValue: raw) {
            return selection
        }
        if UserDefaults.standard.object(forKey: legacyDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: legacyDefaultsKey) ? .webGL : .metal
        }
        #if DEBUG
        return .automatic
        #else
        return .metal
        #endif
    }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .metal:     return "Metal"
        case .webGL:     return "WebGL2"
        }
    }
}
#endif
