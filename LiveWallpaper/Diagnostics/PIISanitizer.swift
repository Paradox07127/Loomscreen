import Foundation

/// Best-effort PII scrubber for log lines, file paths, URLs, and error
/// strings before they reach a user-facing surface (RuntimeErrorBanner,
/// LibraryGuideCard, WeatherStatusBadge) or a publicly-postable bug report.
///
/// Replaces home-directory prefixes, `/Users/<name>` segments, URL userinfo
/// (`https://user:pw@host`), URL query strings, raw geographic coordinates,
/// bearer / basic / token / api-key fragments, IP addresses, `.local`
/// machine hostnames, Steam IDs / account names, and `ssfn*` sentry tokens
/// with `<redacted>` placeholders while preserving enough structure
/// (extensions, DNS hosts, error codes) to keep the message actionable for
/// triage.
enum PIISanitizer {
    static func scrub(_ raw: String) -> String {
        var result = raw

        // Boundary-anchored so a home like `/Users/al` doesn't eat into
        // `/Users/alice` and defeat the `/Users/<name>` rule below.
        if let regex = Self.homePathRegex {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "~")
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

    private static let homePathRegex: NSRegularExpression? = {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else { return nil }
        // `(?=/|$)` keeps the match to a whole path component so a home that is
        // a strict prefix of another user's path (`/Users/al` vs `/Users/alice`)
        // is left for the `/Users/<name>` rule instead of being corrupted here.
        return try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: home) + #"(?=/|$)"#)
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

        // Classes below are ported from `WorkshopDiagnosticRedactor` (Pro-only,
        // so its rules can't be referenced from here) — general surfaces like
        // the bug-report log excerpt must meet the same redaction bar.

        // 17-digit SteamID64 (`7656119` prefix + 10 digits).
        Rule(pattern: #"\b7656119\d{10}\b"#, template: "<steamid-redacted>"),
        // SteamID3 form `[U:1:<accountid>]` as emitted by SteamCMD `+info`.
        Rule(pattern: #"\[U:\d+:\d+\]"#, template: "<steamid-redacted>"),
        // IPv4 dotted quad. Mirrors the Workshop redactor's permissive stance:
        // it does not disambiguate version strings, so a 4-part `1.2.3.4` is
        // deliberately eaten (over-redaction is the safe direction for a
        // publicly-posted report) while the app's real version shapes
        // (`0.2.0`, `15.5.0`) survive because exactly four groups are required.
        Rule(pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, template: "<ip-redacted>"),
        // Compressed IPv6 (`fe80::1`, `2001:db8::8a2e:370:7334`). Must run
        // before the expanded rule below: that one only matches single-colon
        // chains, so on `::` forms it used to eat just the tail and leak the
        // routing prefix (the household-identifying half). The alternation
        // requires ≥1 hex group so a bare `::` survives, and the flanking
        // guards abort on any leftover alnum/colon, so partially-hex tokens
        // (`Foo::bar`, `std::vector`, `fe::bezel`) pass through — only fully
        // hex-shaped tokens (`fe::be`) are eaten, the accepted trade-off.
        Rule(pattern: #"(?<![A-Za-z0-9:])(?:[A-Fa-f0-9]{1,4}(?::[A-Fa-f0-9]{1,4})*::(?:[A-Fa-f0-9]{1,4}(?::[A-Fa-f0-9]{1,4})*)?|::[A-Fa-f0-9]{1,4}(?::[A-Fa-f0-9]{1,4})*)(?![A-Za-z0-9:])"#, template: "<ip-redacted>"),
        // IPv6 expanded form — deliberately permissive (2+ colon-separated hex
        // groups), same accepted false-positive trade-off as the Workshop
        // redactor (e.g. a `00:01:23` duration). ISO-8601 log timestamps are
        // immune: the `T` glues the date to the time, so no word boundary
        // precedes `12:34:56`.
        Rule(pattern: #"\b(?:[A-Fa-f0-9]{1,4}:){2,7}[A-Fa-f0-9]{1,4}\b"#, template: "<ip-redacted>"),
        // Bonjour machine hostnames (`Johns-MacBook-Pro.local`) derive from the
        // user's device name. Scoped to `.local` so ordinary DNS hosts stay
        // readable per the contract above.
        Rule(pattern: #"(?i)\b[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\.local\b"#, template: "<host-redacted>"),
        // `ssfn*` Steam sentry file names (serial-like session tokens).
        Rule(pattern: #"ssfn[A-Za-z0-9]+"#, template: "ssfn<redacted>"),
        // Steam persona / account names. Unlike the Workshop redactor's
        // `^`-anchored line rules, these match mid-line: log lines reach us
        // prefixed with a timestamp, so an anchor would never fire.
        Rule(pattern: #"personaname=[^&\s]+"#, template: "personaname=<redacted>"),
        // Persona is free-form (spaces, kanji, emoji) → eat to end of line.
        Rule(pattern: #"(?i)\b(Persona Name):[ \t]*\S[^\n]*"#, template: "$1: <redacted>"),
        Rule(pattern: #"(?i)\b(Account):[ \t]*\S+"#, template: "$1: <redacted>"),
        // SteamCMD login banner: `Logging in user '<name>' [U:1:N] to Steam…`.
        Rule(pattern: #"Logging in user '[^']+'"#, template: "Logging in user '<redacted>'"),
    ]
}
