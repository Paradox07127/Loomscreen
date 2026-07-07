import Testing
import Foundation
@testable import LiveWallpaper

@Suite("PIISanitizer: regex branches")
struct PIISanitizerTests {

    @Test("Replaces /Users/<name> with /Users/<redacted>")
    func redactsHomeDirectorySegment() {
        let scrubbed = PIISanitizer.scrub("Failed to read /Users/alice/Movies/Sunset.mp4")
        #expect(scrubbed.contains("/Users/<redacted>/Movies/Sunset.mp4"))
        #expect(!scrubbed.contains("alice"))
    }

    @Test("Replaces HOME prefix when set")
    func redactsHomeEnvironmentPrefix() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard !home.isEmpty else { return }
        let raw = "\(home)/Documents/secret.json"
        let scrubbed = PIISanitizer.scrub(raw)
        #expect(scrubbed.hasPrefix("~"))
        #expect(!scrubbed.contains(home))
    }

    @Test("Strips URL query strings")
    func redactsURLQuery() {
        let scrubbed = PIISanitizer.scrub("Fetch https://cdn.x.com/a.mp4?token=abc&lat=37.78 failed")
        #expect(scrubbed.contains("https://cdn.x.com/a.mp4?<query-redacted>"))
        #expect(!scrubbed.contains("token=abc"))
    }

    @Test("Redacts file:// URLs entirely")
    func redactsFileURL() {
        let scrubbed = PIISanitizer.scrub("Loading file:///Users/bob/wallpaper.mov now")
        #expect(scrubbed.contains("file://<redacted>"))
        #expect(!scrubbed.contains("bob"))
    }

    @Test("Redacts standalone latitude / longitude assignments")
    func redactsLatLonAssignments() {
        let scrubbed = PIISanitizer.scrub("URLError -1009: lat=37.7749, longitude: -122.4194")
        #expect(scrubbed.contains("lat=<redacted>"))
        #expect(scrubbed.contains("longitude=<redacted>"))
        #expect(!scrubbed.contains("37.7749"))
        #expect(!scrubbed.contains("-122.4194"))
    }

    @Test("Redacts token / api-key / bearer fragments")
    func redactsTokenAndBearer() {
        let scrubbed1 = PIISanitizer.scrub("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig")
        #expect(scrubbed1.contains("Bearer <redacted>"))
        #expect(!scrubbed1.contains("eyJhbGciOiJIUzI1NiJ9"))

        let scrubbed2 = PIISanitizer.scrub("Set api_key=AKIA1234567890ABCDEF in header")
        #expect(scrubbed2.contains("api_key=<redacted>"))
        #expect(!scrubbed2.contains("AKIA"))
    }

    @Test("Redacts URL userinfo (user:password@host)")
    func redactsURLUserinfo() {
        let scrubbed = PIISanitizer.scrub("Connect https://alice:s3cret@cdn.example.com/asset.mp4 now")
        #expect(scrubbed.contains("https://<redacted>@cdn.example.com"))
        #expect(!scrubbed.contains("alice"))
        #expect(!scrubbed.contains("s3cret"))
    }

    @Test("Redacts Basic authorization headers")
    func redactsBasicAuth() {
        let scrubbed = PIISanitizer.scrub("Authorization: Basic dXNlcjpwYXNzd29yZA==")
        #expect(scrubbed.contains("Basic <redacted>"))
        #expect(!scrubbed.contains("dXNlcjpwYXNzd29yZA"))
    }

    @Test("Preserves non-sensitive content untouched")
    func preservesNonSensitive() {
        let raw = "Decoder downgraded from hardware to software at frame 1024"
        let scrubbed = PIISanitizer.scrub(raw)
        #expect(scrubbed == raw)
    }

    /// Regression: a co-resident account whose name extends the running user's
    /// (`/Users/al` home vs `/Users/alice/…`) must be fully redacted, not turned
    /// into a partial-name leak like `~ice/…` by an unbounded HOME substring pass.
    @Test("Does not leak a username that extends the HOME path")
    func doesNotLeakPrefixExtendingUsername() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard home.hasPrefix("/Users/") else { return }

        // Synthesize a *different* user whose path starts with the real home
        // string but continues past its component boundary. Under the sandboxed
        // test runner HOME is the container path, so build the expectation
        // dynamically: only the /Users/<name> component gets redacted.
        let neighbor = home + "xyz/Movies/private.mov"
        let scrubbed = PIISanitizer.scrub(neighbor)

        var parts = neighbor.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 2 { parts[2] = "<redacted>" }
        let expected = parts.joined(separator: "/")

        #expect(!scrubbed.contains("~"))
        #expect(scrubbed == expected)
    }

    /// The running user's own home is still collapsed to `~` at a component
    /// boundary and leaves no `/Users/<name>` residue behind.
    @Test("Collapses own HOME to ~ at a path boundary")
    func collapsesOwnHomeAtBoundary() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard home.hasPrefix("/Users/") else { return }

        let scrubbed = PIISanitizer.scrub("\(home)/Library/Logs/runtime.log")
        #expect(scrubbed == "~/Library/Logs/runtime.log")
        #expect(!scrubbed.contains("/Users/"))
    }

    // MARK: - Classes ported from WorkshopDiagnosticRedactor

    @Test("Redacts .local machine hostnames but keeps DNS hosts")
    func redactsLocalHostname() {
        let scrubbed = PIISanitizer.scrub("Bonjour registered Johns-MacBook-Pro.local on the network")
        #expect(scrubbed.contains("<host-redacted>"))
        #expect(!scrubbed.contains("Johns-MacBook-Pro"))

        // Ordinary DNS hosts are preserved on purpose (triage value).
        let url = PIISanitizer.scrub("GET https://cdn.example.com/a.mp4 failed")
        #expect(url.contains("cdn.example.com"))
    }

    @Test("Redacts IPv4 addresses")
    func redactsIPv4() {
        let scrubbed = PIISanitizer.scrub("Connection refused from 192.168.1.20:27036")
        #expect(scrubbed.contains("<ip-redacted>:27036"))
        #expect(!scrubbed.contains("192.168.1.20"))
    }

    @Test("Redacts IPv6 addresses")
    func redactsIPv6() {
        let scrubbed = PIISanitizer.scrub("Route via fe80:0:0:0:1ff:fe23:4567:890a is down")
        #expect(scrubbed.contains("Route via <ip-redacted> is down"))
        #expect(!scrubbed.contains("fe23"))
    }

    /// Regression: the expanded-form rule alone never matched `::` shapes —
    /// `fe80::1` passed through untouched and `2001:db8::8a2e:370:7334` lost
    /// only its tail, leaking the routing prefix (the household-identifying
    /// half) into a publicly-postable report.
    @Test("Redacts compressed IPv6 addresses whole, no prefix remnant")
    func redactsCompressedIPv6() {
        let linkLocal = PIISanitizer.scrub("Route via fe80::1 is down")
        #expect(linkLocal == "Route via <ip-redacted> is down")

        let short = PIISanitizer.scrub("Bound to 2001:db8::1 on port 443")
        #expect(short == "Bound to <ip-redacted> on port 443")

        let mixed = PIISanitizer.scrub("Peer 2001:db8::8a2e:370:7334 timed out")
        #expect(mixed == "Peer <ip-redacted> timed out")
        #expect(!mixed.contains("2001"))
        #expect(!mixed.contains("db8"))
    }

    /// The compressed rule must not eat scope-resolution operators, bare `::`,
    /// single-colon diagnostic tags, or the outputs of earlier redaction rules.
    @Test("Compressed IPv6 rule leaves non-address :: shapes alone")
    func preservesNonAddressDoubleColons() {
        #expect(PIISanitizer.scrub("Foo::bar") == "Foo::bar")
        #expect(PIISanitizer.scrub("::") == "::")
        #expect(PIISanitizer.scrub("range :: endIndex") == "range :: endIndex")

        let metal = "program_source:1198:24: error: use of undeclared identifier 'v'"
        #expect(PIISanitizer.scrub(metal) == metal)

        // Idempotence: placeholders from prior rules must not re-match.
        let placeholders = "<steamid-redacted> and <ip-redacted> stay put"
        #expect(PIISanitizer.scrub(placeholders) == placeholders)
    }

    @Test("Redacts SteamID64")
    func redactsSteamID64() {
        let scrubbed = PIISanitizer.scrub("Resolved owner 76561198012345678 for item 3226487183")
        #expect(scrubbed.contains("owner <steamid-redacted>"))
        #expect(!scrubbed.contains("76561198012345678"))
        // Workshop item IDs are not SteamID64-shaped and must survive.
        #expect(scrubbed.contains("3226487183"))
    }

    @Test("Redacts SteamID3")
    func redactsSteamID3() {
        let scrubbed = PIISanitizer.scrub("SteamID: [U:1:1267132100] reported by probe")
        #expect(scrubbed.contains("<steamid-redacted>"))
        #expect(!scrubbed.contains("1267132100"))
    }

    @Test("Redacts Steam account and persona names mid-line")
    func redactsSteamAccountNames() {
        // Mid-line, timestamp-prefixed shapes — the Workshop redactor's
        // `^`-anchored rules would miss these; PIISanitizer must not.
        let account = PIISanitizer.scrub("doctor: Account: gaben_at_home ")
        #expect(account.contains("Account: <redacted>"))
        #expect(!account.contains("gaben_at_home"))

        let persona = PIISanitizer.scrub("probe says Persona Name: 半藏 Hanzo Main and more")
        #expect(persona.contains("Persona Name: <redacted>"))
        #expect(!persona.contains("Hanzo"))

        let banner = PIISanitizer.scrub("Logging in user 'gaben' [U:1:42] to Steam Public...OK")
        #expect(banner.contains("Logging in user '<redacted>'"))
        #expect(banner.contains("<steamid-redacted>"))
        #expect(!banner.contains("gaben"))

        let query = PIISanitizer.scrub("cached personaname=GabeN for 76561198012345678")
        #expect(query.contains("personaname=<redacted>"))
        #expect(!query.contains("GabeN"))
    }

    @Test("Redacts ssfn sentry tokens keeping the ssfn marker")
    func redactsSSFNSentryToken() {
        let scrubbed = PIISanitizer.scrub("removed ssfn1234567890123456789 from container")
        #expect(scrubbed.contains("ssfn<redacted>"))
        #expect(!scrubbed.contains("ssfn1234567890123456789"))
    }

    /// Version strings, ISO-8601 log timestamps, workshop IDs, and file:line
    /// tags must survive the new IP/hostname rules. Three-part versions are
    /// structurally safe (the IPv4 rule requires exactly four groups); the
    /// timestamp is safe because `T` glues date to time with no word boundary
    /// ahead of `12:34:56`.
    @Test("New rules do not eat versions, timestamps, or file:line tags")
    func preservesVersionsTimestampsAndLineTags() {
        let raw = "2026-07-07T12:34:56.789Z [WPE] [ERROR] Render.swift:42 — LiveWallpaper 0.2.0 (417) on macOS 15.5.0"
        #expect(PIISanitizer.scrub(raw) == raw)
    }

    /// Documented over-redaction choice: `WorkshopDiagnosticRedactor` does not
    /// disambiguate 4-part version strings from IPv4 (its comments accept
    /// false positives), and PIISanitizer mirrors that — for a public bug
    /// report, over-redaction is the safe direction.
    @Test("Four-part dotted quads are redacted by design")
    func redactsFourPartDottedQuads() {
        let scrubbed = PIISanitizer.scrub("installer 1.2.3.4 finished")
        #expect(scrubbed == "installer <ip-redacted> finished")
    }

}
