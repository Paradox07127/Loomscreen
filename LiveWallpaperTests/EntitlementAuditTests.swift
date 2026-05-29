#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Security
import Testing

/// Regression guard on the SteamCMD-related App Sandbox posture. Reads the host
/// app's *runtime* entitlements via `SecTask`, so it catches accidental
/// weakening (or loss of a required exception) in the built + signed product,
/// not just the source plist.
@Suite("Entitlement audit — App Sandbox invariants")
struct EntitlementAuditTests {

    private func entitlement(_ key: String) -> CFTypeRef? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    @Test("Sandbox + network + read-only tooling exception are present")
    func requiredEntitlementsPresent() {
        #expect((entitlement("com.apple.security.app-sandbox") as? Bool) == true)
        #expect((entitlement("com.apple.security.network.client") as? Bool) == true)
        // SteamCMD bind()s a UDP socket — without this its login reports "No Connection".
        #expect((entitlement("com.apple.security.network.server") as? Bool) == true)
        #expect((entitlement("com.apple.security.files.bookmarks.app-scope") as? Bool) == true)
        let readOnly = entitlement("com.apple.security.temporary-exception.files.absolute-path.read-only") as? [String] ?? []
        #expect(readOnly.contains("/opt/homebrew/"))
        #expect(readOnly.contains("/usr/local/"))
        #expect(readOnly.contains("/opt/local/"))
    }

    @Test("No sandbox/hardened-runtime weakening or read-write filesystem exceptions")
    func noWeakeningEntitlements() {
        #expect(entitlement("com.apple.security.cs.disable-library-validation") == nil)
        #expect(entitlement("com.apple.security.cs.allow-dyld-environment-variables") == nil)
        // Downloads stay container-local; we never grant write reach outside it.
        #expect(entitlement("com.apple.security.temporary-exception.files.absolute-path.read-write") == nil)
        #expect(entitlement("com.apple.security.temporary-exception.files.home-relative-path.read-write") == nil)
    }
}
#endif
