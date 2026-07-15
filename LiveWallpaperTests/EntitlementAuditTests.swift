#if !LITE_BUILD
import Security
import Testing

/// Regression guard on the App Sandbox posture (SteamCMD + the Monitor board's
/// sensor/process reads). Reads the host app's *runtime* entitlements via
/// `SecTask`, so it catches accidental weakening (or loss of a required
/// exception) in the built + signed product, not just the source plist.
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

    // MARK: - Monitor board (sensor + process instruments)

    /// These two keys are the widest the app carries — `iokit-user-client-class`
    /// admits an arbitrary IOKit user client, `sbpl` injects raw sandbox profile
    /// language. Pin the EXACT contents, not mere membership: a later widget that
    /// quietly appends a rule would otherwise sail through the (release-only)
    /// fingerprint gate's regeneration.
    @Test("Monitor's IOKit + SBPL exceptions are present and exactly scoped")
    func monitorExceptionsExactlyScoped() {
        // AppleSMC temperature/power reads — MonitorSensorSampler's IOServiceOpen.
        let iokit = entitlement("com.apple.security.temporary-exception.iokit-user-client-class") as? [String] ?? []
        #expect(iokit == ["AppleSMCClient"])

        // The per-process walk: proc_listallpids / proc_pidinfo / proc_pid_rusage.
        let sbpl = Set(entitlement("com.apple.security.temporary-exception.sbpl") as? [String] ?? [])
        #expect(sbpl == [
            "(allow process-info-listpids)",
            "(allow process-info-pidinfo)",
            "(allow process-info-rusage)",
        ])
    }

    @Test("The SBPL exception stays read-only — no control or argv operations")
    func sbplGrantsOnlyProcessInfoReads() {
        let sbpl = entitlement("com.apple.security.temporary-exception.sbpl") as? [String] ?? []
        #expect(!sbpl.isEmpty)

        // Every rule must be an `allow` of a process-info READ. In particular this
        // rejects `deny`-shaped or non-process-info rules sneaking in.
        for rule in sbpl {
            #expect(rule.hasPrefix("(allow process-info-"))
        }

        let joined = sbpl.joined(separator: " ")
        // setcontrol/dirtycontrol would let us act ON other processes rather than
        // read them; process-info-argv would expose other apps' command lines,
        // where API keys and tokens routinely sit.
        for forbidden in ["setcontrol", "dirtycontrol", "process-info-argv", "process-info-codesignature"] {
            #expect(!joined.contains(forbidden))
        }
    }
}
#endif
