import Testing
import Foundation
@testable import LiveWallpaper

// MARK: - HTMLTrust pure verdict

@Suite("HTMLTrust verdict")
struct HTMLTrustVerdictTests {

    @Test("file source is local")
    func fileIsLocal() {
        let v = HTMLTrust.evaluate(source: .file(bookmarkData: Data([0x01])), trustedHosts: [])
        #expect(v == .localContent)
    }

    @Test("folder source is local")
    func folderIsLocal() {
        let v = HTMLTrust.evaluate(
            source: .folder(bookmarkData: Data([0x01]), indexFileName: "index.html"),
            trustedHosts: []
        )
        #expect(v == .localContent)
    }

    @Test("inline source is local")
    func inlineIsLocal() {
        let v = HTMLTrust.evaluate(source: .inline("<html></html>"), trustedHosts: [])
        #expect(v == .localContent)
    }

    @Test("URL with no host is local")
    func urlNoHostIsLocal() {
        // URL("about:blank") has no host
        let v = HTMLTrust.evaluate(source: .url(URL(string: "about:blank")!), trustedHosts: [])
        #expect(v == .localContent)
    }

    @Test("Untrusted remote URL is flagged")
    func untrustedRemote() {
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://shadertoy.com/view/abc")!),
            trustedHosts: ["example.com"]
        )
        #expect(v == .untrustedRemote(host: "shadertoy.com"))
    }

    @Test("Trusted remote URL matches by exact host")
    func trustedRemote() {
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://shadertoy.com/view/abc")!),
            trustedHosts: ["shadertoy.com"]
        )
        #expect(v == .trustedRemote(host: "shadertoy.com"))
    }

    @Test("Host comparison is case insensitive (lowercased)")
    func caseInsensitive() {
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://Shadertoy.COM/view/abc")!),
            trustedHosts: ["shadertoy.com"]
        )
        #expect(v == .trustedRemote(host: "shadertoy.com"))
    }

    @Test("Subdomain is NOT auto-trusted")
    func subdomainNotInherited() {
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://api.shadertoy.com/x")!),
            trustedHosts: ["shadertoy.com"]
        )
        #expect(v == .untrustedRemote(host: "api.shadertoy.com"))
    }

    @Test("effectiveAllowJavaScript drops JS for untrusted remote")
    func untrustedDropsJS() {
        let v = HTMLTrust.untrustedRemote(host: "evil.example")
        #expect(v.effectiveAllowJavaScript(requested: true) == false)
        #expect(v.effectiveAllowJavaScript(requested: false) == false)
    }

    @Test("effectiveAllowJavaScript honors request for local + trusted")
    func othersHonorRequest() {
        for v in [HTMLTrust.localContent, .trustedRemote(host: "x.com")] {
            #expect(v.effectiveAllowJavaScript(requested: true) == true)
            #expect(v.effectiveAllowJavaScript(requested: false) == false)
        }
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

    @Test("Loads + normalizes seed (lowercased + deduped + sorted)")
    func loadNormalizes() {
        let (store, _) = makeStore(seed: ["B.com", "a.com", "A.COM", "  c.com  "])
        #expect(store.hosts == ["a.com", "b.com", "c.com"])
    }

    @Test("trust adds new host and persists")
    func trustAdds() {
        let (store, persistence) = makeStore()
        #expect(store.trust("Example.com") == true)
        #expect(store.hosts == ["example.com"])
        #expect(persistence.stored == ["example.com"])
    }

    @Test("trust ignores duplicate host")
    func trustIgnoresDuplicate() {
        let (store, _) = makeStore(seed: ["x.com"])
        #expect(store.trust("x.com") == false)
        #expect(store.trust("X.COM") == false)
        #expect(store.hosts == ["x.com"])
    }

    @Test("trust ignores empty/whitespace input")
    func trustIgnoresEmpty() {
        let (store, _) = makeStore()
        #expect(store.trust("") == false)
        #expect(store.trust("   ") == false)
        #expect(store.hosts.isEmpty)
    }

    @Test("revoke removes host and persists")
    func revokeRemoves() {
        let (store, persistence) = makeStore(seed: ["a.com", "b.com"])
        #expect(store.revoke("A.COM") == true)
        #expect(store.hosts == ["b.com"])
        #expect(persistence.stored == ["b.com"])
    }

    @Test("revoke unknown host is a no-op")
    func revokeUnknown() {
        let (store, _) = makeStore(seed: ["a.com"])
        #expect(store.revoke("missing.com") == false)
        #expect(store.hosts == ["a.com"])
    }

    @Test("contains is case insensitive")
    func containsCaseInsensitive() {
        let (store, _) = makeStore(seed: ["foo.com"])
        #expect(store.contains("FOO.COM"))
        #expect(store.contains("foo.com"))
        #expect(!store.contains("bar.com"))
    }
}
