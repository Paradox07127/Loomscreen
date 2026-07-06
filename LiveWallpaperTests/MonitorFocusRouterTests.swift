import Darwin
import Foundation
import Testing
@testable import LiveWallpaper

/// Pure-logic coverage for `MonitorFocusRouter`: session-id parsing, the
/// parent-process walker (exercised against the running test process), and
/// descriptor→PID matching. No window activation is triggered here.
@Suite("MonitorFocusRouter: parsing + pid walk")
struct MonitorFocusRouterTests {

    // MARK: - parseProvider

    @Test("parses a claude session id")
    func parsesClaude() {
        let parsed = MonitorFocusRouter.parseProvider("claude:abc-123")
        #expect(parsed == .claude(sessionID: "abc-123"))
    }

    @Test("parses a codex session id")
    func parsesCodex() {
        let parsed = MonitorFocusRouter.parseProvider("codex:xyz-789")
        #expect(parsed == .codex(id: "xyz-789"))
    }

    @Test("scheme match is case-insensitive")
    func parsesMixedCaseScheme() {
        #expect(MonitorFocusRouter.parseProvider("Claude:U1") == .claude(sessionID: "U1"))
        #expect(MonitorFocusRouter.parseProvider("CODEX:c1") == .codex(id: "c1"))
    }

    @Test("keeps everything after the first colon as the id")
    func keepsColonsInID() {
        let parsed = MonitorFocusRouter.parseProvider("claude:a:b:c")
        #expect(parsed == .claude(sessionID: "a:b:c"))
    }

    @Test("rejects unknown scheme, missing separator, and empty id")
    func rejectsBadInput() {
        #expect(MonitorFocusRouter.parseProvider("gemini:zzz") == nil)
        #expect(MonitorFocusRouter.parseProvider("no-separator") == nil)
        #expect(MonitorFocusRouter.parseProvider("claude:") == nil)
        #expect(MonitorFocusRouter.parseProvider("") == nil)
    }

    // MARK: - Parent-chain walker

    @Test("parentPID of the test process returns a real ancestor")
    func parentPIDResolves() {
        let me = getpid()
        let parent = MonitorFocusRouter.parentPID(of: me)
        // Every process except launchd (pid 1) has a parent the kernel can report.
        #expect(parent != nil)
        if let parent {
            #expect(parent > 0)
            #expect(parent != me)
        }
    }

    @Test("parentPID of an impossible pid fails gracefully")
    func parentPIDMissing() {
        // INT32_MAX is far above any real pid; sysctl returns no record.
        #expect(MonitorFocusRouter.parentPID(of: pid_t.max) == nil)
    }

    @Test("regularAncestor walk from the test process terminates without crashing")
    func regularAncestorTerminates() {
        // The xctest host is not itself `.regular`; whether a regular ancestor
        // exists depends on how the suite was launched (Xcode vs bare CLI). The
        // contract is only that the bounded walk RETURNS — a pid or nil — and
        // never loops or traps.
        let result = MonitorFocusRouter.regularAncestorPID(from: getpid())
        if let result {
            #expect(result > 0)
        }
    }

    // MARK: - Descriptor matching

    @Test("matches the live descriptor for a session id")
    func matchesLiveDescriptor() {
        let sessionID = "live-session"
        let descriptors = [
            ClaudePIDDescriptor(pid: getpid(), sessionId: sessionID, cwd: nil, kind: nil, name: nil, startedAt: nil)
        ]
        #expect(MonitorFocusRouter.pid(forSessionID: sessionID, in: descriptors) == getpid())
    }

    @Test("returns nil for an unknown session id")
    func unknownSessionReturnsNil() {
        let descriptors = [
            ClaudePIDDescriptor(pid: getpid(), sessionId: "known", cwd: nil, kind: nil, name: nil, startedAt: nil)
        ]
        #expect(MonitorFocusRouter.pid(forSessionID: "not-there", in: descriptors) == nil)
    }

    @Test("skips a dead descriptor and reports no pid")
    func deadDescriptorReturnsNil() {
        // A pid the kernel can't find is treated as dead → no focus target.
        let descriptors = [
            ClaudePIDDescriptor(pid: pid_t.max, sessionId: "ghost", cwd: nil, kind: nil, name: nil, startedAt: nil)
        ]
        #expect(MonitorFocusRouter.pid(forSessionID: "ghost", in: descriptors) == nil)
    }

    @Test("prefers the alive descriptor when a session has several")
    func prefersAliveDescriptor() {
        let sessionID = "dup"
        let descriptors = [
            ClaudePIDDescriptor(pid: pid_t.max, sessionId: sessionID, cwd: nil, kind: nil, name: nil, startedAt: nil),
            ClaudePIDDescriptor(pid: getpid(), sessionId: sessionID, cwd: nil, kind: nil, name: nil, startedAt: nil)
        ]
        #expect(MonitorFocusRouter.pid(forSessionID: sessionID, in: descriptors) == getpid())
    }
}
