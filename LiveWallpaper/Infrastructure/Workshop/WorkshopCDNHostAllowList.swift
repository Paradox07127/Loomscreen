#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation

/// Allow-list for hosts that may serve Workshop preview images and other
/// content URLs returned by Steam Web API responses.
///
/// Implementation follows the canonicalization + suffix-match rules in
/// `docs/2026-05-28-steam-workshop-integration-plan.md` ("CDN host
/// allow-list for `preview_url` / `file_url`"). Reject everything that
/// fails any of: HTTPS-only, no userinfo, port `nil` or 443, IDNA-canonical
/// host, no IP-literal, normalized path, no `..` segments. Suffix match is
/// applied to the canonical host (lowercased, trailing dot stripped).
enum WorkshopCDNHostAllowList {

    /// Result of a check. `.allowed` carries the canonical URL the caller
    /// should use for the actual fetch (post-IDNA, percent-encoded path).
    enum Outcome: Equatable, Sendable {
        case allowed(URL)
        case rejected(reason: RejectionReason)
    }

    enum RejectionReason: String, Equatable, Sendable {
        case nonHTTPS
        case userinfoPresent
        case nonStandardPort
        case ipLiteralHost
        case pathTraversal
        case hostNotAllowed
        case malformedURL
    }

    static func evaluate(_ candidate: String) -> Outcome {
        guard let components = URLComponents(string: candidate) else {
            return .rejected(reason: .malformedURL)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "https" else {
            return .rejected(reason: .nonHTTPS)
        }
        if components.user != nil || components.password != nil {
            return .rejected(reason: .userinfoPresent)
        }
        if let port = components.port, port != 443 {
            return .rejected(reason: .nonStandardPort)
        }
        guard var host = components.host?.lowercased(), !host.isEmpty else {
            return .rejected(reason: .hostNotAllowed)
        }
        // Strip a trailing dot if present (root-zone canonical form).
        if host.hasSuffix(".") { host.removeLast() }

        if Self.isIPLiteral(host) {
            return .rejected(reason: .ipLiteralHost)
        }
        // `..` would be normalized away by `standardizedFileURL` for file
        // URLs, but for http(s) we have to inspect the raw path ourselves.
        let path = components.path
        if path.split(separator: "/").contains("..") {
            return .rejected(reason: .pathTraversal)
        }
        guard Self.matchesAllowList(host: host) else {
            return .rejected(reason: .hostNotAllowed)
        }

        var canonical = components
        canonical.host = host
        guard let canonicalURL = canonical.url else {
            return .rejected(reason: .malformedURL)
        }
        return .allowed(canonicalURL)
    }

    // MARK: - Private

    /// Hosts must match one of:
    /// - `*.steamstatic.com`  (covers akamai / cloudflare flavors)
    /// - `*.steamusercontent.com`  (current Workshop preview CDN — empirically
    ///   confirmed 2026-05-28 against `images.steamusercontent.com` returning
    ///   the preview URL for WE item 3725117707; the host stays the same
    ///   regardless of which underlying CDN — Akamai / Cloudflare / AliyunOSS
    ///   in CN — Valve points it at)
    /// - `media.steampowered.com`  (exact — do NOT wildcard `*.steampowered.com`,
    ///   which would admit `account.steampowered.com` and similar sensitive
    ///   subdomains)
    /// - `*.akamaihd.net` where the leftmost label has prefix `steamuserimages-`
    ///   or `steamcdn-` (older Workshop preview path; still seen on legacy
    ///   responses)
    private static func matchesAllowList(host: String) -> Bool {
        if host == "media.steampowered.com" { return true }
        if host.hasSuffix(".steamstatic.com") { return true }
        if host.hasSuffix(".steamusercontent.com") { return true }
        if host.hasSuffix(".akamaihd.net") {
            let leftmost = host.split(separator: ".").first.map(String.init) ?? ""
            return leftmost.hasPrefix("steamuserimages-")
                || leftmost.hasPrefix("steamcdn-")
        }
        return false
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        // IPv6 in URL host appears bracketed in URLComponents.host? No —
        // URLComponents.host strips the brackets, so bare IPv6 has colons.
        if host.contains(":") { return true }
        // IPv4 dotted-quad: all labels are decimal numbers.
        let labels = host.split(separator: ".")
        if labels.count == 4, labels.allSatisfy({ Int($0) != nil }) {
            return true
        }
        return false
    }
}
#endif
