import AppKit
import Darwin
import Foundation
import os

/// Routes a "focus this session" request (from the Fleet HUD) to the terminal / editor window that owns the agent process.
@MainActor
enum MonitorFocusRouter {
    // `nonisolated` so the detached descriptor/PID-walk task and the nonisolated walker below can read them without hopping back to the main actor; both are immutable and `Logger` is `Sendable`.
    nonisolated private static let log = Logger(subsystem: "com.livewallpaper", category: "MonitorFocus")

    /// Cap on how far up the process tree we walk before giving up — a healthy terminal → shell → agent chain is only a few hops; the cap guards against a pathological / cyclic table.
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
            log.info("Monitor focus: not supported for codex sessions yet")
        case .claude(let claudeSessionID):
            focusClaude(sessionID: claudeSessionID)
        }
    }

    private static func focusClaude(sessionID: String) {
        // Snapshot the descriptors on the main actor (the auth store's ephemeral security scope is MainActor-isolated and the reads are a handful of tiny JSON files), then move the unbounded parent-chain walk off-main.
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

    /// Reads `~/.claude/sessions/<PID>.json` descriptors through the auth store's ephemeral scope, reusing `ClaudeSessionScanner`'s parser.
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

    /// Brings the app that owns `ownerPID` to the front.
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

    /// Parses `"claude:<uuid>"` / `"codex:<id>"`.
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

    /// Finds the live PID for `sessionID` among `descriptors`, preferring an alive process (guards against PID reuse the same way the scanner does).
    nonisolated static func pid(forSessionID sessionID: String, in descriptors: [ClaudePIDDescriptor]) -> pid_t? {
        let matches = descriptors.filter { $0.sessionId == sessionID }
        guard !matches.isEmpty else { return nil }
        let scanner = ClaudeSessionScanner(rootURL: URL(fileURLWithPath: "/"))
        return matches.first(where: { scanner.isAlive($0) })?.pid
    }

    /// Walks the parent-process chain from `startPID` and returns the first PID whose owning app is `.regular` (Dock-visible) — the window a user would expect a click to raise.
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
