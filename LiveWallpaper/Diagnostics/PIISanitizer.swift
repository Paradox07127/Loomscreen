import Foundation

/// Best-effort PII scrubber for log lines, file paths, URLs, and error
/// strings before they reach a user-facing surface (RuntimeErrorBanner,
/// LibraryGuideCard, WeatherStatusBadge) or a publicly-postable bug report.
///
/// Replaces home-directory prefixes, `/Users/<name>` segments, URL userinfo
/// (`https://user:pw@host`), URL query strings, raw geographic coordinates,
/// and bearer / basic / token / api-key fragments with `<redacted>`
/// placeholders while preserving enough structure (extensions, hosts, error
/// codes) to keep the message actionable for triage.
enum PIISanitizer {
    static func scrub(_ raw: String) -> String {
        var result = raw

        if let home = Self.homePath {
            result = result.replacingOccurrences(of: home, with: "~")
        }

        for rule in Self.rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: rule.template
            )
        }

        return result
    }

    // MARK: - Precompiled rules

    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(pattern: String, template: String) {
            self.regex = try! NSRegularExpression(pattern: pattern)
            self.template = template
        }
    }

    private static let homePath: String? = {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else { return nil }
        return home
    }()

    private static let rules: [Rule] = [
        // `/Users/<name>` (or `/Volumes/.../Users/<name>`) → keep relative path useful for triage.
        Rule(pattern: #"/Users/[^/\s'"]+"#, template: "/Users/<redacted>"),
        // URL userinfo: `https://user:pw@host` → `https://<redacted>@host`.
        Rule(pattern: #"(https?://)[^/\s'"@]+@([^/\s'"]+)"#, template: "$1<redacted>@$2"),
        // URL query strings: signed CDN params, tokens, email-shaped params.
        Rule(pattern: #"(https?://[^\s'"]+)\?[^\s'"]*"#, template: "$1?<query-redacted>"),
        // file:// URLs in full.
        Rule(pattern: #"file://[^\s'"]+"#, template: "file://<redacted>"),
        // Standalone lat/lon assignments — re-thrown error strings sometimes
        // surface coordinates without a host (`URL Error -1009: lat=37.7…`).
        Rule(pattern: #"(?i)\b(lat(?:itude)?|lon(?:gitude)?)\s*[=:]\s*-?\d{1,3}(?:\.\d+)?"#, template: "$1=<redacted>"),
        // token / api-key / password assignments.
        Rule(pattern: #"(?i)\b(token|api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password)\s*[=:]\s*([^&\s'"]+)"#, template: "$1=<redacted>"),
        // Bearer / Token authorization headers.
        Rule(pattern: #"(?i)\b(Bearer|Token)\s+[A-Za-z0-9._~+/=-]+"#, template: "$1 <redacted>"),
        // Basic authorization headers — base64 of `user:pw` is just as sensitive.
        Rule(pattern: #"(?i)\bBasic\s+[A-Za-z0-9+/=]+"#, template: "Basic <redacted>"),
    ]
}
