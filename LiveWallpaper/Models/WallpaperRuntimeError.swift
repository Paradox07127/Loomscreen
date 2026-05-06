import Foundation

/// User-visible runtime errors raised by a wallpaper session.
/// Surfaced through `WallpaperRuntimeSession.runtimeError` and rendered by
/// `RuntimeErrorBanner` in screen-detail UI so failures stop being silent.
enum WallpaperRuntimeError: Error, Equatable, Sendable {
    case fileAccessDenied(URL)
    case mediaNotPlayable(URL, code: Int?)
    case webNavigationFailed(URL, code: Int?, description: String)
    case networkOffline
    case sandboxRevoked

    var userMessage: String {
        switch self {
        case .fileAccessDenied(let url):
            return "Cannot access \(url.lastPathComponent). Re-pick the source to restore permission."
        case .mediaNotPlayable(let url, let code):
            if let code {
                return "The video \(url.lastPathComponent) cannot be played (error \(code))."
            }
            return "The video \(url.lastPathComponent) cannot be played."
        case .webNavigationFailed(let url, let code, let description):
            if let code {
                return "The HTML wallpaper at \(url.absoluteString) failed to load (error \(code)): \(description)"
            }
            return "The HTML wallpaper at \(url.absoluteString) failed to load: \(description)"
        case .networkOffline:
            return "The network appears to be offline."
        case .sandboxRevoked:
            return "File permission expired. Re-pick the source to restore access."
        }
    }

    var canRetry: Bool {
        switch self {
        case .fileAccessDenied, .sandboxRevoked:
            return false
        case .mediaNotPlayable, .webNavigationFailed, .networkOffline:
            return true
        }
    }
}
