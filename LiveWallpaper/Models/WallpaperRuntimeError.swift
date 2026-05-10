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
            return String(localized: "Cannot access \(url.lastPathComponent). Re-pick the source to restore permission.", comment: "Runtime error message. The placeholder is a file name.")
        case .mediaNotPlayable(let url, let code):
            if let code {
                return String(localized: "The video \(url.lastPathComponent) cannot be played (error \(code)).", comment: "Runtime error message. Placeholders are file name and error code.")
            }
            return String(localized: "The video \(url.lastPathComponent) cannot be played.", comment: "Runtime error message. The placeholder is a file name.")
        case .webNavigationFailed(let url, let code, let description):
            if let code {
                return String(localized: "The HTML wallpaper at \(url.absoluteString) failed to load (error \(code)): \(description)", comment: "Runtime error message. Placeholders are URL, error code, and system description.")
            }
            return String(localized: "The HTML wallpaper at \(url.absoluteString) failed to load: \(description)", comment: "Runtime error message. Placeholders are URL and system description.")
        case .networkOffline:
            return String(localized: "The network appears to be offline.", defaultValue: "The network appears to be offline.", comment: "Runtime error message.")
        case .sandboxRevoked:
            return String(localized: "File permission expired. Re-pick the source to restore access.", defaultValue: "File permission expired. Re-pick the source to restore access.", comment: "Runtime error message.")
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
