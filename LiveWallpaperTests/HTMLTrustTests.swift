import Testing
import Foundation
import LiveWallpaperCore
@testable import LiveWallpaper

// MARK: - HTMLTrust pure verdict

@Suite("HTMLTrust verdict")
struct HTMLTrustVerdictTests {

    @Test("file source is local")
    func fileIsLocal() {
        let v = HTMLTrust.evaluate(source: .file(bookmarkData: Data([0x01])), trustedOrigins: [])
        #expect(v == .localContent)
    }

    @Test("folder source is local")
    func folderIsLocal() {
        let v = HTMLTrust.evaluate(
            source: .folder(bookmarkData: Data([0x01]), indexFileName: "index.html"),
            trustedOrigins: []
        )
        #expect(v == .localContent)
    }

    @Test("inline source is local")
    func inlineIsLocal() {
        let v = HTMLTrust.evaluate(source: .inline("<html></html>"), trustedOrigins: [])
        #expect(v == .localContent)
    }

    @Test("URL with no host is local")
    func urlNoHostIsLocal() {
        let v = HTMLTrust.evaluate(source: .url(URL(string: "about:blank")!), trustedOrigins: [])
        #expect(v == .localContent)
    }

    @Test("Untrusted remote URL is flagged")
    func untrustedRemote() throws {
        let expected = try #require(TrustedHTMLOrigin(url: URL(string: "https://shadertoy.com/view/abc")!))
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://shadertoy.com/view/abc")!),
            trustedOrigins: [try #require(TrustedHTMLOrigin(url: URL(string: "https://example.com")!))]
        )
        #expect(v == .untrustedRemote(origin: expected))
    }

    @Test("Trusted remote URL matches by exact origin")
    func trustedRemote() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://shadertoy.com/view/abc")!))
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://shadertoy.com/view/abc")!),
            trustedOrigins: [origin]
        )
        #expect(v == .trustedRemote(origin: origin))
    }

    @Test("Origin comparison is case insensitive for scheme and host")
    func caseInsensitive() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://shadertoy.com")!))
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://Shadertoy.COM/view/abc")!),
            trustedOrigins: [origin]
        )
        #expect(v == .trustedRemote(origin: origin))
    }

    @Test("Subdomain is NOT auto-trusted")
    func subdomainNotInherited() throws {
        let trusted = try #require(TrustedHTMLOrigin(url: URL(string: "https://shadertoy.com")!))
        let expected = try #require(TrustedHTMLOrigin(url: URL(string: "https://api.shadertoy.com/x")!))
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://api.shadertoy.com/x")!),
            trustedOrigins: [trusted]
        )
        #expect(v == .untrustedRemote(origin: expected))
    }

    @Test("Trust does not cross URL scheme")
    func schemeNotInherited() throws {
        let trusted = try #require(TrustedHTMLOrigin(url: URL(string: "https://example.com")!))
        let expected = try #require(TrustedHTMLOrigin(url: URL(string: "http://example.com")!))

        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "http://example.com/wallpaper")!),
            trustedOrigins: [trusted]
        )

        #expect(v == .untrustedRemote(origin: expected))
    }

    @Test("Trust does not cross explicit port")
    func portNotInherited() throws {
        let trusted = try #require(TrustedHTMLOrigin(url: URL(string: "https://example.com")!))
        let expected = try #require(TrustedHTMLOrigin(url: URL(string: "https://example.com:8443")!))

        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://example.com:8443/wallpaper")!),
            trustedOrigins: [trusted]
        )

        #expect(v == .untrustedRemote(origin: expected))
    }

    @Test("effectiveAllowJavaScript drops JS for untrusted remote")
    func untrustedDropsJS() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://evil.example")!))
        let v = HTMLTrust.untrustedRemote(origin: origin)
        #expect(v.effectiveAllowJavaScript(requested: true) == false)
        #expect(v.effectiveAllowJavaScript(requested: false) == false)
    }

    @Test("effectiveAllowJavaScript honors request for local + trusted")
    func othersHonorRequest() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://x.com")!))
        for v in [HTMLTrust.localContent, .trustedRemote(origin: origin)] {
            #expect(v.effectiveAllowJavaScript(requested: true) == true)
            #expect(v.effectiveAllowJavaScript(requested: false) == false)
        }
    }

    @Test("effectiveMuteAudio force-mutes untrusted remote regardless of request")
    func untrustedRemoteForcesMute() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://evil.example")!))
        let v = HTMLTrust.untrustedRemote(origin: origin)
        #expect(v.effectiveMuteAudio(requested: false) == true)
        #expect(v.effectiveMuteAudio(requested: true) == true)
        #expect(v.effectiveAudioVolume(requested: 1.0) == 0)
        #expect(v.effectiveAudioVolume(requested: 0.5) == 0)
        #expect(v.effectiveAudioVolume(requested: 0.0) == 0)
    }

    @Test("effectiveMuteAudio passes request through for local + trusted")
    func othersHonorAudioRequest() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://x.com")!))
        for v in [HTMLTrust.localContent, .trustedRemote(origin: origin)] {
            #expect(v.effectiveMuteAudio(requested: false) == false)
            #expect(v.effectiveMuteAudio(requested: true) == true)
            #expect(v.effectiveAudioVolume(requested: 0.7) == 0.7)
            #expect(v.effectiveAudioVolume(requested: 0.0) == 0.0)
        }
    }

    @Test("Origin raw value includes scheme, host, and effective port")
    func originRawValueIncludesTransportBoundary() throws {
        let defaultHTTPS = try #require(TrustedHTMLOrigin(url: URL(string: "https://Example.COM/path")!))
        let explicitHTTPS = try #require(TrustedHTMLOrigin(url: URL(string: "https://example.com:8443/path")!))

        #expect(defaultHTTPS.rawValue == "https://example.com:443")
        #expect(defaultHTTPS.displayName == "https://example.com")
        #expect(explicitHTTPS.rawValue == "https://example.com:8443")
        #expect(explicitHTTPS.displayName == "https://example.com:8443")
    }
}

// MARK: - TrustedHostStore

@MainActor
private final class InMemoryTrustedHostPersistence: TrustedHostPersisting {
    var stored: [String] = []
    func load() -> [String] { stored }
    func save(_ hosts: [String]) { stored = hosts }
}

@Suite("TrustedHostStore")
@MainActor
struct TrustedHostStoreTests {

    private func makeStore(seed: [String] = []) -> (TrustedHostStore, InMemoryTrustedHostPersistence) {
        let p = InMemoryTrustedHostPersistence()
        p.stored = seed
        return (TrustedHostStore(persistence: p), p)
    }

    @Test("Loads + normalizes seed into secure origins")
    func loadNormalizes() {
        let (store, _) = makeStore(seed: ["B.com", "https://a.com:443", "A.COM", "  https://c.com:8443  ", "http://plain.example:80"])
        #expect(store.origins.map(\.rawValue) == [
            "https://a.com:443",
            "https://b.com:443",
            "https://c.com:8443",
        ])
    }

    @Test("Loading legacy hosts persists canonical origin migration")
    func loadMigratesLegacyHostsToPersistedOrigins() {
        let (store, persistence) = makeStore(seed: ["Example.com", "https://already.com:443", "http://plain.example:80"])

        #expect(store.origins.map(\.rawValue) == [
            "https://already.com:443",
            "https://example.com:443",
        ])
        #expect(persistence.stored == [
            "https://already.com:443",
            "https://example.com:443",
        ])
    }

    @Test("trust adds new secure origin and persists")
    func trustAdds() throws {
        let (store, persistence) = makeStore()
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://Example.com/path")!))

        #expect(store.trust(origin) == true)
        #expect(store.origins.map(\.rawValue) == ["https://example.com:443"])
        #expect(persistence.stored == ["https://example.com:443"])
    }

    @Test("trust rejects insecure HTTP origins")
    func trustRejectsHTTP() throws {
        let (store, persistence) = makeStore()
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "http://example.com")!))

        #expect(store.trust(origin) == false)
        #expect(store.origins.isEmpty)
        #expect(persistence.stored.isEmpty)
    }

    @Test("trust ignores duplicate origin")
    func trustIgnoresDuplicate() throws {
        let (store, _) = makeStore(seed: ["https://x.com:443"])
        let canonical = try #require(TrustedHTMLOrigin(url: URL(string: "https://x.com")!))
        let equivalent = try #require(TrustedHTMLOrigin(url: URL(string: "https://X.COM:443/path")!))

        #expect(store.trust(canonical) == false)
        #expect(store.trust(equivalent) == false)
        #expect(store.origins.map(\.rawValue) == ["https://x.com:443"])
    }

    @Test("revoke removes origin and persists")
    func revokeRemoves() throws {
        let (store, persistence) = makeStore(seed: ["https://a.com:443", "https://b.com:8443"])
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://A.COM")!))

        #expect(store.revoke(origin) == true)
        #expect(store.origins.map(\.rawValue) == ["https://b.com:8443"])
        #expect(persistence.stored == ["https://b.com:8443"])
    }

    @Test("revoke unknown origin is a no-op")
    func revokeUnknown() throws {
        let (store, _) = makeStore(seed: ["https://a.com:443"])
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://missing.com")!))

        #expect(store.revoke(origin) == false)
        #expect(store.origins.map(\.rawValue) == ["https://a.com:443"])
    }

    @Test("contains is exact to origin boundaries")
    func containsExactOrigin() throws {
        let (store, _) = makeStore(seed: ["foo.com"])
        let httpsDefault = try #require(TrustedHTMLOrigin(url: URL(string: "https://FOO.COM")!))
        let httpDefault = try #require(TrustedHTMLOrigin(url: URL(string: "http://foo.com")!))
        let httpsOtherPort = try #require(TrustedHTMLOrigin(url: URL(string: "https://foo.com:8443")!))

        #expect(store.contains(httpsDefault))
        #expect(store.contains(url: URL(string: "https://foo.com/path")!))
        #expect(!store.contains(httpDefault))
        #expect(!store.contains(httpsOtherPort))
        #expect(!store.contains(url: URL(string: "https://bar.com/path")!))
    }
}
