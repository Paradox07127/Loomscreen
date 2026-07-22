import Testing
import Foundation
import LiveWallpaperCore
@testable import LiveWallpaper

@Suite("HTMLSource(userInput:) parsing")
struct HTMLSourceParsingTests {

    @Test("Bare https:// URL with host is accepted")
    func bareHTTPSURL() {
        let parsed = HTMLSource(userInput: "https://example.com")
        guard case .url(let url) = parsed else {
            Issue.record("Expected .url, got \(String(describing: parsed))")
            return
        }
        #expect(url.host == "example.com")
    }

    @Test("Hostless http:// is rejected as URL (falls through to inline)")
    func hostlessHTTPRejected() {
        let parsed = HTMLSource(userInput: "http://")
        if case .url = parsed {
            Issue.record("Hostless http:// must not become a URL source")
        }
    }

    @Test("http:///path is rejected as URL")
    func hostlessHTTPWithPathRejected() {
        let parsed = HTMLSource(userInput: "http:///path")
        if case .url = parsed {
            Issue.record("http:///path must not become a URL source")
        }
    }

    @Test("Bare host with TLD is upgraded to https://")
    func bareHostWithTLD() {
        let parsed = HTMLSource(userInput: "example.com")
        guard case .url(let url) = parsed else {
            Issue.record("Expected .url, got \(String(describing: parsed))")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == "example.com")
    }

    @Test("localhost:3000 parses as URL")
    func localhostWithPort() {
        let parsed = HTMLSource(userInput: "localhost:3000")
        guard case .url(let url) = parsed else {
            Issue.record("Expected .url for localhost:3000, got \(String(describing: parsed))")
            return
        }
        #expect(url.host == "localhost")
        #expect(url.port == 3000)
    }

    @Test("127.0.0.1:3000 parses as URL")
    func bareIPWithPort() {
        let parsed = HTMLSource(userInput: "127.0.0.1:3000")
        guard case .url(let url) = parsed else {
            Issue.record("Expected .url for 127.0.0.1:3000, got \(String(describing: parsed))")
            return
        }
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 3000)
    }

    @Test("HTML snippet falls through to inline")
    func htmlSnippetInline() {
        let parsed = HTMLSource(userInput: "<p>hi</p>")
        guard case .inline(let html) = parsed else {
            Issue.record("Expected .inline, got \(String(describing: parsed))")
            return
        }
        #expect(html == "<p>hi</p>")
    }

    @Test("Inline JS with dot does not become a URL")
    func inlineJSDotNotURL() {
        let parsed = HTMLSource(userInput: #"console.log("hello")"#)
        if case .url = parsed {
            Issue.record("Inline JS must not be parsed as a URL")
        }
    }

    @Test("Relative path with dotted file does not become a URL")
    func relativePathNotURL() {
        let parsed = HTMLSource(userInput: "foo/bar.html")
        if case .url = parsed {
            Issue.record("Relative path foo/bar.html must not become https://foo/bar.html")
        }
    }

    @Test("CSS rule with dot does not become a URL")
    func cssRuleNotURL() {
        let parsed = HTMLSource(userInput: "border-radius: 4px;")
        if case .url = parsed {
            Issue.record("CSS rule must not be parsed as a URL")
        }
    }

    @Test("Leading dot does not become a URL")
    func leadingDotNotURL() {
        let parsed = HTMLSource(userInput: ".foo")
        if case .url = parsed {
            Issue.record(".foo must not be parsed as a URL")
        }
    }

    @Test("Empty input returns nil")
    func emptyInputNil() {
        #expect(HTMLSource(userInput: "") == nil)
        #expect(HTMLSource(userInput: "   ") == nil)
    }

    @Test("youtube.com/watch?v=ID rewrites to youtube-nocookie embed")
    func youtubeWatchToEmbed() {
        let parsed = HTMLSource(userInput: "https://www.youtube.com/watch?v=d56mG7DezGs")
        guard case .url(let url) = parsed else {
            Issue.record("Expected .url, got \(String(describing: parsed))")
            return
        }
        #expect(url.host == "www.youtube-nocookie.com")
        #expect(url.path == "/embed/d56mG7DezGs")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let names = Set(items.map(\.name))
        #expect(names.contains("autoplay"))
        #expect(names.contains("loop"))
        #expect(names.contains("playlist"))
        #expect(items.first(where: { $0.name == "playlist" })?.value == "d56mG7DezGs")
    }

    @Test("youtu.be/ID rewrites to embed")
    func youtuBeToEmbed() {
        let parsed = HTMLSource(userInput: "https://youtu.be/d56mG7DezGs")
        guard case .url(let url) = parsed else {
            Issue.record("Expected .url, got \(String(describing: parsed))")
            return
        }
        #expect(url.host == "www.youtube-nocookie.com")
        #expect(url.path == "/embed/d56mG7DezGs")
    }

    @Test("youtube.com/shorts/ID rewrites to embed")
    func youtubeShortsToEmbed() {
        let parsed = HTMLSource(userInput: "https://www.youtube.com/shorts/abc123XYZ_-")
        guard case .url(let url) = parsed else {
            Issue.record("Expected .url, got \(String(describing: parsed))")
            return
        }
        #expect(url.host == "www.youtube-nocookie.com")
        #expect(url.path == "/embed/abc123XYZ_-")
    }

    @Test("Pre-formed embed URLs are not double-rewritten")
    func embedUrlPassesThrough() {
        let raw = "https://www.youtube.com/embed/d56mG7DezGs?autoplay=1"
        let parsed = HTMLSource(userInput: raw)
        guard case .url(let url) = parsed else {
            Issue.record("Expected .url, got \(String(describing: parsed))")
            return
        }
        #expect(url.absoluteString == raw)
    }

    @Test("Non-YouTube URLs pass through unchanged")
    func nonYouTubePassesThrough() {
        let parsed = HTMLSource(userInput: "https://shadertoy.com/view/abc")
        guard case .url(let url) = parsed else {
            Issue.record("Expected .url, got \(String(describing: parsed))")
            return
        }
        #expect(url.host == "shadertoy.com")
    }

    @Test("Malformed video ID does not trigger rewrite")
    func malformedIDFallback() {
        let parsed = HTMLSource(userInput: "https://www.youtube.com/watch?v=bad/id")
        guard case .url(let url) = parsed else {
            Issue.record("Expected .url, got \(String(describing: parsed))")
            return
        }
        #expect(url.host == "www.youtube.com")
    }
}
