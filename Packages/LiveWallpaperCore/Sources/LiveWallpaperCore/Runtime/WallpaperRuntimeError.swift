import Foundation

/// User-visible runtime errors raised by a wallpaper session.
/// Surfaced through `WallpaperRuntimeSession.runtimeError` and rendered by
/// `RuntimeErrorBanner` in screen-detail UI so failures stop being silent.
public enum WallpaperRuntimeError: Error, Equatable, Sendable {
    case fileAccessDenied(URL)
    case mediaNotPlayable(URL, code: Int?)
    case webNavigationFailed(URL, code: Int?, description: String)
    case networkOffline
    case sandboxRevoked

    public var userMessage: String {
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

    public var canRetry: Bool {
        switch self {
        case .fileAccessDenied, .sandboxRevoked:
            return false
        case .mediaNotPlayable, .webNavigationFailed, .networkOffline:
            return true
        }
    }

    public enum Severity: Sendable { case error, warning, info }

    /// `error` is unrecoverable without user action; `warning` is recoverable;
    /// `info` is a degraded-mode notice.
    public var severity: Severity {
        switch self {
        case .fileAccessDenied, .sandboxRevoked, .mediaNotPlayable:
            return .error
        case .webNavigationFailed:
            return .warning
        case .networkOffline:
            return .info
        }
    }

    public var title: String {
        switch self {
        case .fileAccessDenied(let url):
            return String(localized: "Cannot access \(url.lastPathComponent)", comment: "Runtime error title. The placeholder is the file name.")
        case .mediaNotPlayable(let url, _):
            return String(localized: "Video unavailable: \(url.lastPathComponent)", comment: "Runtime error title. The placeholder is the file name.")
        case .webNavigationFailed(let url, _, _):
            return String(localized: "HTML wallpaper failed to load: \(url.host ?? url.absoluteString)", comment: "Runtime error title. The placeholder is the URL host or full URL.")
        case .networkOffline:
            return String(localized: "Network offline", defaultValue: "Network offline", comment: "Runtime error title.")
        case .sandboxRevoked:
            return String(localized: "File permission expired", defaultValue: "File permission expired", comment: "Runtime error title.")
        }
    }

    /// Middle-truncated path / URL; nil for errors with no associated path.
    public var subtitlePath: String? {
        switch self {
        case .fileAccessDenied(let url),
             .mediaNotPlayable(let url, _):
            return middleTruncated(url.path, maxLength: 60)
        case .webNavigationFailed(let url, _, _):
            return middleTruncated(url.absoluteString, maxLength: 60)
        case .networkOffline, .sandboxRevoked:
            return nil
        }
    }

    /// VoiceOver consumers see the full, un-truncated path.
    public var accessibilityDetail: String {
        switch self {
        case .fileAccessDenied(let url),
             .mediaNotPlayable(let url, _):
            return url.path
        case .webNavigationFailed(let url, _, _):
            return url.absoluteString
        case .networkOffline:
            return ""
        case .sandboxRevoked:
            return ""
        }
    }

    private func middleTruncated(_ string: String, maxLength: Int) -> String {
        guard string.count > maxLength else { return string }
        let keep = maxLength - 1
        let head = keep / 2
        let tail = keep - head
        return string.prefix(head) + "…" + string.suffix(tail)
    }
}
