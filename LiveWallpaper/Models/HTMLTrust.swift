import Foundation

/// Verdict of whether the running HTML wallpaper source is safe to give
/// JavaScript + WebGPU privileges. UI shows a banner + builder downgrades
/// untrusted remote URLs to JS-off regardless of HTMLConfig.allowJavaScript.
enum HTMLTrust: Equatable {
    /// Local file / folder / inline string — fully under user control.
    case localContent
    /// Remote URL whose host is in TrustedHostStore.
    case trustedRemote(host: String)
    /// Remote URL whose host is NOT in TrustedHostStore.
    case untrustedRemote(host: String)

    /// Pure verdict — host membership decided by caller.
    static func evaluate(source: HTMLSource, trustedHosts: Set<String>) -> HTMLTrust {
        switch source {
        case .file, .folder, .inline:
            return .localContent
        case .url(let url):
            guard let host = url.host?.lowercased(), !host.isEmpty else {
                return .localContent
            }
            return trustedHosts.contains(host) ? .trustedRemote(host: host) : .untrustedRemote(host: host)
        }
    }

    /// Effective JS gate: untrusted remote always forces JS off.
    func effectiveAllowJavaScript(requested: Bool) -> Bool {
        switch self {
        case .untrustedRemote: return false
        default: return requested
        }
    }
}
