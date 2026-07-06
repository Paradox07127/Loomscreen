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

}
