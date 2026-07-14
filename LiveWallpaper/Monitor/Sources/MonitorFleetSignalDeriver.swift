import Foundation

/// Pure, I/O-free derivations for the v2 Fleet signals shared by both the Claude
/// and Codex session models. Everything here is metadata-only: tool NAMES,
/// timestamps, token counts, and status — never prompt text, arguments, output,
/// or paths beyond a display component.
enum MonitorFleetSignalDeriver {
    /// Cap on retained per-session event timestamps (the tick track window).
    static let recentEventCap = 60
    /// Cap on retained per-session tool events surfaced to the board.
    static let recentToolCap = 8

    /// A tool-loop warning fires when the last `toolLoopRun` consecutive tool
    /// events share one name inside `toolLoopWindow`.
    static let toolLoopRun = 8
    static let toolLoopWindow: TimeInterval = 10 * 60

    /// A running+alive session with no new event for longer than this is "stale".
    static let staleAfter: TimeInterval = 5 * 60

    /// Max characters a sanitized tool name may keep. Real tool names are short
    /// identifiers; anything longer is a smell (or an injection attempt) and gets
    /// dropped rather than truncated.
    static let toolNameMaxLength = 64

    /// Characters a tool name may contain. Deliberately narrow: identifier letters
    /// and digits plus the few separators real tool names use (`_ . : -`). Anything
    /// with whitespace, punctuation, quotes, newlines, or non-ASCII fails.
    private static let toolNameAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-"
    )

    /// Sanitize a raw tool name pulled verbatim from a transcript before it is ever
    /// stored or rendered as a "tool name" in the UI. A malformed / malicious
    /// transcript could otherwise smuggle prompt-like text into that slot. Applies
    /// an allowlist charset + length cap and normalizes a dotted-namespace name to
    /// its last component (`mcp__foo.bar` → `bar`); returns nil (drop) on any
    /// failure rather than emitting attacker-controlled text.
    static func sanitizedToolName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= toolNameMaxLength else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ toolNameAllowed.contains($0) }) else { return nil }
        let name = trimmed.split(separator: ".").last.map(String.init) ?? trimmed
        return name.isEmpty ? nil : name
    }

    /// Keep the most recent `cap` timestamps, ascending. Input may arrive in any
    /// order; output is sorted so the renderer can walk it left-to-right.
    static func trimmedEventTimes(_ times: [Double], cap: Int = recentEventCap) -> [Double]? {
        guard !times.isEmpty else { return nil }
        let sorted = times.sorted()
        let capped = sorted.count > cap ? Array(sorted.suffix(cap)) : sorted
        return capped
    }

    /// Keep the most recent `cap` tool events by timestamp, ascending.
    static func trimmedTools(_ tools: [MonitorAgentToolEvent], cap: Int = recentToolCap) -> [MonitorAgentToolEvent]? {
        guard !tools.isEmpty else { return nil }
        let sorted = tools.sorted { $0.at < $1.at }
        let capped = sorted.count > cap ? Array(sorted.suffix(cap)) : sorted
        return capped
    }

    /// `(input + cacheRead) ÷ contextWindow`, clamped to 0…1. nil when the model
    /// is unknown or no usage-bearing assistant event has been seen yet.
    static func contextUsedPercent(
        lastInputTokens: Int?,
        lastCacheReadTokens: Int?,
        model: String?
    ) -> Double? {
        guard let window = MonitorModelContextCatalog.contextWindow(for: model), window > 0 else { return nil }
        guard lastInputTokens != nil || lastCacheReadTokens != nil else { return nil }
        let used = Double((lastInputTokens ?? 0) + (lastCacheReadTokens ?? 0))
        return min(1, max(0, used / Double(window)))
    }

    /// Derive the anomaly flag.
    ///
    /// - `toolLoop` when the last `toolLoopRun` tool events share a name inside
    ///   `toolLoopWindow` (an agent stuck retrying one tool).
    /// - `stale` when the session is running + processAlive but has emitted no
    ///   event for longer than `staleAfter`.
    /// - nil otherwise. Loop takes precedence over stale.
    static func warning(
        recentTools: [MonitorAgentToolEvent],
        status: MonitorAgentStatus,
        processAlive: Bool,
        lastEventAt: Double?,
        now: Double
    ) -> String? {
        if isToolLoop(recentTools) { return "toolLoop" }
        if status == .running, processAlive, let last = lastEventAt, now - last > staleAfter {
            return "stale"
        }
        return nil
    }

    /// True when the most recent `toolLoopRun` tool events (by time) all carry the
    /// same name and span at most `toolLoopWindow`.
    static func isToolLoop(_ tools: [MonitorAgentToolEvent]) -> Bool {
        guard tools.count >= toolLoopRun else { return false }
        let tail = Array(tools.sorted { $0.at < $1.at }.suffix(toolLoopRun))
        guard let first = tail.first, let last = tail.last else { return false }
        guard last.at - first.at <= toolLoopWindow else { return false }
        return tail.allSatisfy { $0.name == first.name }
    }
}

/// Worktree name extraction from a session cwd. Emits the last path component
/// ONLY when the cwd lives inside a `.claude/worktrees/` directory; otherwise nil.
/// Never emits the full path (privacy invariant — display names only).
enum MonitorWorktree {
    static func name(fromCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let components = (cwd as NSString).pathComponents
        // Find the ".../.claude/worktrees/<name>/..." segment and take the segment
        // immediately after "worktrees". The worktree name is that first segment,
        // not deeper subpaths, so nested cwds still resolve to the worktree root.
        guard let worktreesIndex = components.firstIndex(where: { $0 == "worktrees" }),
              worktreesIndex >= 1, components[worktreesIndex - 1] == ".claude",
              worktreesIndex + 1 < components.count else {
            return nil
        }
        let name = components[worktreesIndex + 1]
        return name.isEmpty || name == "/" ? nil : name
    }
}

/// In-memory tracker of when each session's status last flipped INTO `needsInput`,
/// keyed by session id. The flip time is captured on the transition and carried
/// while the session stays blocked, then cleared when it leaves `needsInput`.
///
/// Lives outside the pure session models (which are rebuilt on rotation) so the
/// wait clock survives rescans; the owning source keeps one tracker for its whole
/// lifetime.
struct MonitorFleetWaitTracker {
    private var waitSince: [String: Double] = [:]

    /// Update the tracked flip time for `sessionId` given its current status and
    /// the event time to stamp a fresh transition with. Returns the effective
    /// `waitSince` (nil unless currently blocked).
    mutating func waitSince(
        sessionID: String,
        status: MonitorAgentStatus,
        eventTime: Double
    ) -> Double? {
        if status == .needsInput {
            if let existing = waitSince[sessionID] { return existing }
            waitSince[sessionID] = eventTime
            return eventTime
        } else {
            waitSince[sessionID] = nil
            return nil
        }
    }

    /// Drop tracking for sessions no longer in the live set so the map can't grow
    /// unbounded across a long-lived app.
    mutating func retainOnly(_ liveIDs: Set<String>) {
        waitSince = waitSince.filter { liveIDs.contains($0.key) }
    }
}
