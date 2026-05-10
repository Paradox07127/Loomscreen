import Foundation

/// Security boundary for a remote HTML wallpaper.
///
/// Web content trust follows browser origin rules: scheme + host + effective
/// port. Trusting `https://example.com` must not grant JavaScript privileges to
/// `http://example.com`, `https://example.com:8443`, or subdomains.
struct TrustedHTMLOrigin: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard
            let rawScheme = url.scheme?.lowercased(),
            rawScheme == "http" || rawScheme == "https",
            let rawHost = url.host?.lowercased(),
            !rawHost.isEmpty,
            let effectivePort = url.port ?? Self.defaultPort(for: rawScheme)
        else { return nil }

        scheme = rawScheme
        host = rawHost
        port = effectivePort
    }

    /// Accepts new persisted origin strings (`https://host:443`) plus legacy
    /// host-only values, which migrate to HTTPS on the default port.
    init?(persistedValue: String) {
        let value = persistedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.contains("://") {
            guard let url = URL(string: value), let origin = TrustedHTMLOrigin(url: url) else { return nil }
            self = origin
            return
        }

        let host = value.lowercased()
        guard
            !host.isEmpty,
            host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            !host.contains("/"),
            !host.contains(":")
        else { return nil }

        scheme = "https"
        self.host = host
        port = 443
    }

    var rawValue: String {
        "\(scheme)://\(host):\(port)"
    }

    var displayName: String {
        if port == Self.defaultPort(for: scheme) {
            return "\(scheme)://\(host)"
        }
        return rawValue
    }

    var description: String { rawValue }

    var isSecure: Bool { scheme == "https" }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    static func < (lhs: TrustedHTMLOrigin, rhs: TrustedHTMLOrigin) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let origin = TrustedHTMLOrigin(persistedValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid trusted HTML origin: \(raw)"
            )
        }
        self = origin
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Verdict of whether the running HTML wallpaper source is safe to give
/// JavaScript + WebGPU privileges. UI shows a banner + builder downgrades
/// untrusted remote URLs to JS-off regardless of HTMLConfig.allowJavaScript.
enum HTMLTrust: Equatable {
    /// Local file / folder / inline string — fully under user control.
    case localContent
    /// Remote URL whose origin is in TrustedHostStore.
    case trustedRemote(origin: TrustedHTMLOrigin)
    /// Remote URL whose origin is NOT in TrustedHostStore.
    case untrustedRemote(origin: TrustedHTMLOrigin)

    /// Pure verdict — origin membership decided by caller.
    static func evaluate(source: HTMLSource, trustedOrigins: Set<TrustedHTMLOrigin>) -> HTMLTrust {
        switch source {
        case .file, .folder, .inline:
            return .localContent
        case .url(let url):
            guard let origin = TrustedHTMLOrigin(url: url) else {
                return .localContent
            }
            return trustedOrigins.contains(origin) ? .trustedRemote(origin: origin) : .untrustedRemote(origin: origin)
        }
    }

    /// Compatibility shim for legacy host-only callers. Host values migrate to
    /// HTTPS default-port origins before comparison.
    static func evaluate(source: HTMLSource, trustedHosts: Set<String>) -> HTMLTrust {
        let origins = Set(trustedHosts.compactMap(TrustedHTMLOrigin.init(persistedValue:)))
        return evaluate(source: source, trustedOrigins: origins)
    }

    /// Effective JS gate: untrusted remote always forces JS off.
    func effectiveAllowJavaScript(requested: Bool) -> Bool {
        switch self {
        case .untrustedRemote: return false
        default: return requested
        }
    }
}
