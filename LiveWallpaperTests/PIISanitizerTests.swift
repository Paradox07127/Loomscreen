import Testing
import Foundation
@testable import LiveWallpaper

@Suite("PIISanitizer: regex branches")
struct PIISanitizerTests {

    @Test("Collapses another user's absolute path to its leaf")
    func redactsHomeDirectorySegment() {
        let scrubbed = PIISanitizer.scrub("Failed to read /Users/alice/Movies/Sunset.mp4")
        #expect(scrubbed.contains("<path>/Sunset.mp4"))
        #expect(!scrubbed.contains("alice"))
        #expect(!scrubbed.contains("Movies"))
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

    @Test("Strips custom-scheme nonce and URL fragments")
    func redactsCustomSchemeSecrets() {
        let nonce = PIISanitizer.scrub(
            "Failed livewallpaper://wallpaper/index.html?n=session-secret"
        )
        #expect(nonce.contains("livewallpaper://wallpaper/index.html?<query-redacted>"))
        #expect(!nonce.contains("session-secret"))

        let fragment = PIISanitizer.scrub("Redirect app://trusted/callback#access-token")
        #expect(fragment.contains("app://trusted/callback#<fragment-redacted>"))
        #expect(!fragment.contains("access-token"))
    }

    @Test("Collapses mounted and private absolute paths to their leaf")
    func redactsNonHomeAbsolutePaths() {
        let scrubbed = PIISanitizer.scrub(
            "Copy /Volumes/Studio/ClientX/secret.mov via /private/var/folders/ab/session.json"
        )
        #expect(scrubbed.contains("<path>/secret.mov"))
        #expect(scrubbed.contains("<path>/session.json"))
        #expect(!scrubbed.contains("Studio"))
        #expect(!scrubbed.contains("folders"))
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

    @Test("Does not leak a username that extends the HOME path")
    func doesNotLeakPrefixExtendingUsername() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard home.hasPrefix("/Users/") else { return }

        let neighbor = home + "xyz/Movies/private.mov"
        let scrubbed = PIISanitizer.scrub(neighbor)

        #expect(!scrubbed.contains("~"))
        #expect(scrubbed == "<path>/private.mov")
    }

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

    @Test("Compressed IPv6 rule leaves non-address :: shapes alone")
    func preservesNonAddressDoubleColons() {
        #expect(PIISanitizer.scrub("Foo::bar") == "Foo::bar")
        #expect(PIISanitizer.scrub("::") == "::")
        #expect(PIISanitizer.scrub("range :: endIndex") == "range :: endIndex")

        let metal = "program_source:1198:24: error: use of undeclared identifier 'v'"
        #expect(PIISanitizer.scrub(metal) == metal)

        let placeholders = "<steamid-redacted> and <ip-redacted> stay put"
        #expect(PIISanitizer.scrub(placeholders) == placeholders)
    }

    @Test("Redacts SteamID64")
    func redactsSteamID64() {
        let scrubbed = PIISanitizer.scrub("Resolved owner 76561198012345678 for item 3226487183")
        #expect(scrubbed.contains("owner <steamid-redacted>"))
        #expect(!scrubbed.contains("76561198012345678"))
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

    @Test("New rules do not eat versions, timestamps, or file:line tags")
    func preservesVersionsTimestampsAndLineTags() {
        let raw = "2026-07-07T12:34:56.789Z [WPE] [ERROR] Render.swift:42 — LiveWallpaper 0.2.0 (417) on macOS 15.5.0"
        #expect(PIISanitizer.scrub(raw) == raw)
    }

    @Test("Four-part dotted quads are redacted by design")
    func redactsFourPartDottedQuads() {
        let scrubbed = PIISanitizer.scrub("installer 1.2.3.4 finished")
        #expect(scrubbed == "installer <ip-redacted> finished")
    }

}
