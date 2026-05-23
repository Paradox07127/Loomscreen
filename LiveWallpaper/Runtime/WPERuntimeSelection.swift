#if !LITE_BUILD
import Foundation

enum WPERuntimeSelection: String, Sendable, CaseIterable {
    case metal
    case webGL = "webgl"

    static let defaultsKey = "WPEUseWebGLRuntime"

    static var current: WPERuntimeSelection {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: defaultsKey) {
            return .webGL
        }
        #endif
        return .metal
    }

    var displayName: String {
        switch self {
        case .metal: return "Metal (SPIRV-Cross)"
        case .webGL: return "WebGL2 (WKWebView)"
        }
    }
}
#endif
