import AppKit
import Darwin
import Foundation
import os

/// Routes a "focus this session" request (from the Fleet HUD) to the terminal /
/// editor window that owns the agent process.
///
/// The HUD hands us `"<provider>:<id>"`. For a Claude session we look up the
/// recorded PID in `~/.claude/sessions/<PID>.json`, walk the parent-process chain
/// until we reach a regular (Dock-visible) app — Terminal, iTerm2, WezTerm, VS Code,
/// or Claude Code desktop all qualify — and activate it. Codex has no PID
/// descriptors yet, so it is a logged no-op.
///
/// The descriptor read and PID walk run off the main thread (a busy `sysctl`
/// loop must not stall the wallpaper); only `NSRunningApplication.activate()`
/// hops back to the main actor.
@MainActor
enum MonitorFocusRouter {
    // `nonisolated` so the detached descriptor/PID-walk task and the nonisolated
    // walker below can read them without hopping back to the main actor; both
    // are immutable and `Logger` is `Sendable`.
    nonisolated private static let log = Logger(subsystem: "com.livewallpaper", category: "MonitorFocus")

    /// Cap on how far up the process tree we walk before giving up — a healthy
    /// terminal → shell → agent chain is only a few hops; the cap guards against
    /// a pathological / cyclic table.
    nonisolated private static let maxParentWalkDepth = 15

    enum Provider: Equatable {
        case claude(sessionID: String)
        case codex(id: String)
    }

    // MARK: - Entry point

    static func focus(sessionID: String) {
        guard let provider = parseProvider(sessionID) else {
            log.warning("Monitor focus: unrecognized session id \(sessionID, privacy: .public)")
            return
        }

        switch provider {
        case .codex:
            // Codex writes no `sessions/<PID>.json` descriptors, so there is no
            // PID to resolve and nothing to activate.
            log.info("Monitor focus: not supported for codex sessions yet")
        case .claude(let claudeSessionID):
            focusClaude(sessionID: claudeSessionID)
        }
    }

    private static func focusClaude(sessionID: String) {
        // Snapshot the descriptors on the main actor (the auth store's ephemeral
        // security scope is MainActor-isolated and the reads are a handful of
        // tiny JSON files), then move the unbounded parent-chain walk off-main.
        let descriptors = readClaudeDescriptors()
        guard !descriptors.isEmpty else {
            log.info("Monitor focus: no Claude PID descriptors (grant missing or no live sessions)")
            return
        }

        Task.detached(priority: .userInitiated) {
            guard let leafPID = pid(forSessionID: sessionID, in: descriptors) else {
                Self.log.info("Monitor focus: no live PID for Claude session \(sessionID, privacy: .public)")
                return
            }
            // Descriptors are forgeable JSON in the user's home; only walk and
            // activate when the leaf actually looks like a Claude CLI process.
            guard leafExecutableLooksLikeClaude(leafPID) else {
                Self.log.warning("Monitor focus: leaf pid \(leafPID, privacy: .public) is not a claude/node/bun executable; refusing to activate")
                return
            }
            let target = regularAncestorPID(from: leafPID)
            await MainActor.run {
                activate(ownerPID: target ?? leafPID)
            }
        }
    }

    /// Reads `~/.claude/sessions/<PID>.json` descriptors through the auth store's
    /// ephemeral scope, reusing `ClaudeSessionScanner`'s parser. Empty when the
    /// grant is missing or the directory is unreadable.
    private static func readClaudeDescriptors() -> [ClaudePIDDescriptor] {
        MonitorSourceAuthorization.shared.withResolvedClaudeRoot { root in
            ClaudeSessionScanner(rootURL: root).loadPIDDescriptors()
        } ?? []
    }

    nonisolated private static func leafExecutableLooksLikeClaude(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return false }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        let name = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).lastPathComponent.lowercased()
        return name == "claude" || name == "node" || name == "bun"
    }

    // MARK: - Activation

    /// Brings the app that owns `ownerPID` to the front. Prefers the regular app
    /// found by the parent walk; if `ownerPID` itself has no running-app record
    /// (e.g. a bare helper), this is a logged no-op.
    private static func activate(ownerPID: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: ownerPID) else {
            log.info("Monitor focus: pid \(ownerPID, privacy: .public) has no NSRunningApplication; nothing to activate")
            return
        }
        app.activate()
        let bundleID = app.bundleIdentifier ?? "<unknown>"
        log.info("Monitor focus: activated \(bundleID, privacy: .public) (pid \(ownerPID, privacy: .public))")
    }

    // MARK: - Pure helpers (unit-tested)

    /// Parses `"claude:<uuid>"` / `"codex:<id>"`. The id may itself contain
    /// colons (unusual, but keep everything after the first separator), so we
    /// split once. Unknown prefixes and empty ids return `nil`.
    nonisolated static func parseProvider(_ raw: String) -> Provider? {
        guard let separator = raw.firstIndex(of: ":") else { return nil }
        let scheme = raw[raw.startIndex..<separator].lowercased()
        let id = String(raw[raw.index(after: separator)...])
        guard !id.isEmpty else { return nil }
        switch scheme {
        case "claude": return .claude(sessionID: id)
        case "codex":  return .codex(id: id)
        default:       return nil
        }
    }

    /// Finds the live PID for `sessionID` among `descriptors`, preferring an
    /// alive process (guards against PID reuse the same way the scanner does).
    /// Returns `nil` when the session is unknown or its process is gone.
    /// `isAlive` reads no filesystem state, so the dummy scanner root is inert.
    nonisolated static func pid(forSessionID sessionID: String, in descriptors: [ClaudePIDDescriptor]) -> pid_t? {
        let matches = descriptors.filter { $0.sessionId == sessionID }
        guard !matches.isEmpty else { return nil }
        let scanner = ClaudeSessionScanner(rootURL: URL(fileURLWithPath: "/"))
        return matches.first(where: { scanner.isAlive($0) })?.pid
    }

    /// Walks the parent-process chain from `startPID` and returns the first PID
    /// whose owning app is `.regular` (Dock-visible) — the window a user would
    /// expect a click to raise. Returns `nil` if none is found within the depth
    /// cap (caller falls back to the leaf pid's owner).
    ///
    /// `NSRunningApplication` is thread-safe for lookups, so this can run off the
    /// main actor; only the eventual `activate()` needs MainActor.
    nonisolated static func regularAncestorPID(from startPID: pid_t) -> pid_t? {
        var current: pid_t = startPID
        var depth = 0
        while depth < maxParentWalkDepth {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular {
                return current
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else {
                return nil
            }
            current = parent
            depth += 1
        }
        return nil
    }

    /// Parent PID via `sysctl(KERN_PROC_PID)`. Best-effort — `nil` on any
    /// failure so the walker stops cleanly.
    nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
