import Foundation

/// One decoded transcript line, tolerant of unknown shapes.
///
/// Decoded via `JSONSerialization` (not `Decodable`) so that unrecognized line
/// types — `queue-operation`, `attachment`, `last-prompt`, `custom-title`, and
/// anything future — never throw; they simply carry whatever fields they have.
struct ClaudeTranscriptLine {
    enum Role: Equatable {
        case user
        case assistant
        case system
        case other(String)
    }

    var type: Role
    var timestamp: Date?
    var isSidechain: Bool
    var cwd: String?
    var gitBranch: String?
    var sessionId: String?

    // assistant specifics
    var model: String?
    var stopReason: String?
    var toolNames: [String]          // names of tool_use content blocks, in order
    var toolUses: [ToolUse]          // tool_use blocks with their ids, in order
    var toolResults: [ToolResult]    // tool_result blocks (paired back by tool_use_id)
    var hasTextOutput: Bool          // assistant emitted a text/thinking block
    var usage: Usage?                // flattened assistant token usage, if present

    /// One tool_use content block, name + optional id (name only — never args).
    struct ToolUse: Equatable { var name: String; var id: String? }
    /// One tool_result content block: which tool_use it answers + error marker.
    struct ToolResult: Equatable { var toolUseID: String?; var isError: Bool }

    /// Flattened assistant token usage. Reads only the four canonical top-level
    /// fields; nested `iterations`/`cache_creation` detail is ignored.
    struct Usage: Equatable {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
    }

    // user specifics
    var isToolResult: Bool           // content is a tool_result array (not a real prompt)
    var isRealUserPrompt: Bool       // content is a plain string or text block(s)

    // system specifics
    var rawLineForHeuristics: String // only retained for the permission-substring probe

    /// Parse a single JSONL line. Returns nil only when the bytes are not an
    /// object at all; unknown *types* still decode successfully.
    init?(data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else { return nil }
        self.init(dict: dict, rawUTF8: String(data: data, encoding: .utf8))
    }

    init(dict: [String: Any], rawUTF8: String? = nil) {
        let typeString = dict["type"] as? String ?? "other"
        switch typeString {
        case "user": self.type = .user
        case "assistant": self.type = .assistant
        case "system": self.type = .system
        default: self.type = .other(typeString)
        }

        self.timestamp = (dict["timestamp"] as? String).flatMap(Self.parseTimestamp)
        self.isSidechain = dict["isSidechain"] as? Bool ?? false
        self.cwd = dict["cwd"] as? String
        self.gitBranch = dict["gitBranch"] as? String
        self.sessionId = dict["sessionId"] as? String

        let message = dict["message"] as? [String: Any]
        self.model = message?["model"] as? String
        self.stopReason = message?["stop_reason"] as? String

        var tools: [String] = []
        var toolUses: [ToolUse] = []
        var toolResults: [ToolResult] = []
        var sawText = false
        var sawToolResult = false
        var sawTextContentBlock = false

        if let content = message?["content"] as? [[String: Any]] {
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    if let name = block["name"] as? String {
                        tools.append(name)
                        toolUses.append(ToolUse(name: name, id: block["id"] as? String))
                    }
                case "text", "thinking":
                    sawText = true
                    sawTextContentBlock = true
                case "tool_result":
                    sawToolResult = true
                    // `is_error` is the only field read; the result content itself
                    // (which may contain output) is never touched.
                    let isError = (block["is_error"] as? Bool) ?? false
                    toolResults.append(ToolResult(toolUseID: block["tool_use_id"] as? String, isError: isError))
                default:
                    break
                }
            }
        }
        self.toolNames = tools
        self.toolUses = toolUses
        self.toolResults = toolResults
        self.hasTextOutput = sawText

        if self.type == .assistant, let usageDict = message?["usage"] as? [String: Any] {
            self.usage = Usage(
                input: (usageDict["input_tokens"] as? Int) ?? 0,
                output: (usageDict["output_tokens"] as? Int) ?? 0,
                cacheRead: (usageDict["cache_read_input_tokens"] as? Int) ?? 0,
                cacheWrite: (usageDict["cache_creation_input_tokens"] as? Int) ?? 0
            )
        } else {
            self.usage = nil
        }

        // Real user prompts arrive either as a bare string or as text blocks;
        // tool results arrive as a tool_result array. Only the former counts as
        // a turn.
        let contentIsString = message?["content"] is String
        self.isToolResult = (self.type == .user) && sawToolResult && !contentIsString
        self.isRealUserPrompt = (self.type == .user) && (contentIsString || (sawTextContentBlock && !sawToolResult))

        self.rawLineForHeuristics = (self.type == .system) ? (rawUTF8 ?? "") : ""
    }

    static func parseTimestamp(_ string: String) -> Date? {
        // `ISO8601FormatStyle` is a Sendable value type — no shared mutable
        // formatter to trip Swift 6 concurrency checks. The default style parses
        // both fractional ("…:05.444Z") and whole-second transcript stamps.
        try? Date(string, strategy: .iso8601)
    }
}

/// Pure, I/O-free accumulator + classifier for one Claude Code session.
///
/// Fed parsed lines in file order via `ingest(_:)`, it derives display fields,
/// token totals, and a privacy-safe status. All decisions are deterministic
/// functions of the ingested lines plus `(now, processAlive)`, so the whole
/// thing is unit-testable without touching the filesystem.
struct ClaudeSessionModel {
    private(set) var sessionId: String
    private(set) var projectName: String?
    private(set) var gitBranch: String?
    private(set) var model: String?

    private(set) var turnCount: Int = 0
    private(set) var tokens: MonitorTokenTotals = .zero
    private(set) var lastEventAt: Date?
    private(set) var startedAt: Date?
    private(set) var lastToolName: String?
    private(set) var cwd: String?

    private(set) var pendingToolUse: Bool = false
    private(set) var lastAssistantStopReason: String?
    private(set) var sawPermissionRequest: Bool = false

    // v2 Fleet raw material.
    /// input + cacheRead of the LAST usage-bearing assistant event (context load).
    private(set) var lastUsageInput: Int?
    private(set) var lastUsageCacheRead: Int?
    /// Recent event timestamps (epoch seconds), capped + ascending on read.
    private(set) var recentEventTimes: [Double] = []
    /// Recent tool_use events with ok resolved from the paired tool_result.
    private(set) var recentTools: [MonitorAgentToolEvent] = []

    // Whether the most recent main-session line was a tool_result or a real user
    // prompt (i.e. the model is expected to act next) — a "running" signal per spec.
    private(set) var lastInboundAwaitsModel: Bool = false

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    mutating func ingest(_ line: ClaudeTranscriptLine) {
        // Every timestamped line advances freshness, even sidechain and unknown
        // types — the process is demonstrably alive and writing.
        if let ts = line.timestamp {
            if lastEventAt == nil || ts > lastEventAt! { lastEventAt = ts }
            if startedAt == nil || ts < startedAt! { startedAt = ts }
        }
        if sessionId.isEmpty, let sid = line.sessionId { sessionId = sid }
        if let cwd = line.cwd, !cwd.isEmpty {
            projectName = (cwd as NSString).lastPathComponent
            self.cwd = cwd
        }
        if let branch = line.gitBranch, !branch.isEmpty { gitBranch = branch }

        // Any timestamped main-or-side line contributes a tick to the event track.
        if let ts = line.timestamp?.timeIntervalSince1970 {
            recentEventTimes.append(ts)
            if recentEventTimes.count > MonitorFleetSignalDeriver.recentEventCap * 2 {
                recentEventTimes = Array(recentEventTimes.suffix(MonitorFleetSignalDeriver.recentEventCap))
            }
        }

        // Sidechain (subagent) lines update freshness but never the main
        // session's turns, status inputs, or token/model attribution.
        guard !line.isSidechain else { return }

        switch line.type {
        case .assistant:
            if let model = line.model { self.model = model }
            accumulateTokens(from: line)
            recordLastUsage(from: line)
            recordToolUses(from: line)
            if let stop = line.stopReason { lastAssistantStopReason = stop }
            if let tool = line.toolNames.last {
                // A tool_use with no following tool_result yet: the model is
                // waiting on a tool, not on us. The name is rendered verbatim as a
                // "tool name" chip, so sanitize it before storing — a malformed
                // transcript could otherwise smuggle prompt-like text here. If the
                // name fails the allowlist we still know a tool is pending; we just
                // don't surface a garbage detail (lastToolName stays nil).
                lastToolName = MonitorFleetSignalDeriver.sanitizedToolName(tool)
                pendingToolUse = true
            } else {
                // An assistant text turn with no tool call ends the exchange; the
                // model is no longer mid-action.
                pendingToolUse = false
            }
            // The assistant just spoke — nothing is awaiting the model, and any
            // prior permission prompt is superseded.
            lastInboundAwaitsModel = false
            sawPermissionRequest = false

        case .user:
            if line.isToolResult {
                // Tool result closes the loop opened by the matching tool_use and
                // hands control back to the model.
                applyToolResults(from: line)
                pendingToolUse = false
                lastInboundAwaitsModel = true
            } else if line.isRealUserPrompt {
                turnCount += 1
                pendingToolUse = false
                lastInboundAwaitsModel = true
            }
            // A newer user line supersedes any pending approval request.
            sawPermissionRequest = false

        case .system:
            // Conservative approval probe: only a system line literally mentioning
            // permission/approval flips the flag. Cleared by any newer user or
            // assistant line (handled in those branches).
            let lowered = line.rawLineForHeuristics.lowercased()
            if lowered.contains("permission") || lowered.contains("approval") {
                sawPermissionRequest = true
            }

        case .other:
            break
        }
    }

    private mutating func accumulateTokens(from line: ClaudeTranscriptLine) {
        guard let usage = line.usage else { return }
        tokens.input += usage.input
        tokens.output += usage.output
        tokens.cacheRead += usage.cacheRead
        tokens.cacheWrite += usage.cacheWrite
    }

    /// Context load = the LAST usage-bearing assistant event's input + cache-read.
    private mutating func recordLastUsage(from line: ClaudeTranscriptLine) {
        guard let usage = line.usage else { return }
        lastUsageInput = usage.input
        lastUsageCacheRead = usage.cacheRead
    }

    /// Append each tool_use as an unresolved event (ok = nil) and keep the tail
    /// bounded. Names only — arguments are never read, and each name is sanitized
    /// (allowlist + length cap) before storing so nothing attacker-controlled ever
    /// reaches the tool-name UI. A name that fails sanitization is dropped; the
    /// paired tool_result then resolves the next remaining event (still positional
    /// among the events we kept).
    private mutating func recordToolUses(from line: ClaudeTranscriptLine) {
        let at = line.timestamp?.timeIntervalSince1970 ?? lastEventAt?.timeIntervalSince1970 ?? 0
        for use in line.toolUses {
            guard let name = MonitorFleetSignalDeriver.sanitizedToolName(use.name) else { continue }
            recentTools.append(MonitorAgentToolEvent(name: name, at: at, ok: nil))
        }
        if recentTools.count > MonitorFleetSignalDeriver.recentToolCap * 3 {
            recentTools = Array(recentTools.suffix(MonitorFleetSignalDeriver.recentToolCap * 3))
        }
    }

    /// Resolve `ok` on the tool events this user line's tool_results answer. The
    /// wire event carries no id, so pairing is positional: each result resolves the
    /// oldest still-unresolved event (Claude Code delivers results in call order).
    /// Only `is_error` is read — result content is never inspected.
    private mutating func applyToolResults(from line: ClaudeTranscriptLine) {
        for result in line.toolResults {
            guard let index = recentTools.firstIndex(where: { $0.ok == nil }) else { break }
            recentTools[index].ok = !result.isError
        }
    }

    // MARK: - Classification

    /// Derive the current status. Ladder order matters — the first matching rule
    /// wins, mirroring the worker spec exactly.
    func status(now: Date, processAlive: Bool, freshnessTimeout: TimeInterval = 180) -> MonitorAgentStatus {
        let age = lastEventAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let isFresh = age < 15
        let isVeryStale = age >= freshnessTimeout

        // 1. Blocked on human approval (only meaningful while the process lives).
        if sawPermissionRequest && processAlive {
            return .needsInput
        }
        // 2. Actively working: recent activity plus an outstanding tool call or a
        //    just-delivered tool_result / user prompt the model must answer.
        if isFresh && (pendingToolUse || lastInboundAwaitsModel) {
            return .running
        }
        // 3. Cleanly finished its turn and the process is still up: idle, ready.
        if lastAssistantStopReason == "end_turn" && processAlive {
            return .idle
        }
        // 4. No activity for a long while: idle if alive, otherwise ended.
        if isVeryStale {
            return processAlive ? .idle : .ended
        }
        // 5. Process gone and not fresh: the session has ended.
        if !processAlive {
            return .ended
        }
        // 6. Fresh but ambiguous ⇒ running; otherwise unknown.
        return isFresh ? .running : .unknown
    }

    /// Short, privacy-safe detail string. Only ever a tool name — never any
    /// prompt or output text (hard privacy invariant).
    func statusDetail(now: Date, processAlive: Bool, freshnessTimeout: TimeInterval = 180) -> String? {
        guard status(now: now, processAlive: processAlive, freshnessTimeout: freshnessTimeout) == .running else { return nil }
        return pendingToolUse ? lastToolName : nil
    }

    func costUSD() -> Double? {
        guard let model else { return nil }
        return MonitorTokenPricing.cost(model: model, tokens: tokens)
    }

    /// Metadata-derived fleet signals (everything except waitSince, which the
    /// owning source overlays from its cross-scan flip tracker).
    func contextUsedPercent() -> Double? {
        MonitorFleetSignalDeriver.contextUsedPercent(
            lastInputTokens: lastUsageInput,
            lastCacheReadTokens: lastUsageCacheRead,
            model: model
        )
    }

    var worktreeName: String? { MonitorWorktree.name(fromCwd: cwd) }

    /// Snapshot into the frozen wire type.
    func snapshot(now: Date, processAlive: Bool, freshnessTimeout: TimeInterval = 180) -> MonitorAgentSessionState {
        let currentStatus = status(now: now, processAlive: processAlive, freshnessTimeout: freshnessTimeout)
        let tools = MonitorFleetSignalDeriver.trimmedTools(recentTools)
        let warning = MonitorFleetSignalDeriver.warning(
            recentTools: recentTools,
            status: currentStatus,
            processAlive: processAlive,
            lastEventAt: lastEventAt?.timeIntervalSince1970,
            now: now.timeIntervalSince1970
        )
        var state = MonitorAgentSessionState(
            id: "claude:\(sessionId)",
            provider: .claude,
            projectName: projectName ?? sessionId,
            status: currentStatus,
            statusDetail: statusDetail(now: now, processAlive: processAlive, freshnessTimeout: freshnessTimeout),
            model: model,
            gitBranch: gitBranch,
            startedAt: startedAt?.timeIntervalSince1970,
            lastEventAt: (lastEventAt ?? .distantPast).timeIntervalSince1970,
            processAlive: processAlive,
            turnCount: turnCount,
            tokens: tokens,
            costUSD: costUSD()
        )
        state.recentEventTimes = MonitorFleetSignalDeriver.trimmedEventTimes(recentEventTimes)
        state.recentTools = tools
        state.contextUsedPercent = contextUsedPercent()
        state.warning = warning
        state.worktreeName = worktreeName
        return state
    }

    func snapshotState() -> SessionAggregateState {
        SessionAggregateState(
            provider: .claude,
            sessionId: sessionId,
            projectName: projectName,
            gitBranch: gitBranch,
            model: model,
            turnCount: turnCount,
            tokens: tokens,
            startedAt: startedAt?.timeIntervalSince1970,
            lastEventAt: lastEventAt?.timeIntervalSince1970,
            lastToolName: lastToolName,
            pendingToolUse: pendingToolUse,
            lastAssistantStopReason: lastAssistantStopReason,
            sawPermissionRequest: sawPermissionRequest,
            lastInboundAwaitsModel: lastInboundAwaitsModel
        )
    }

    static func restore(from state: SessionAggregateState) -> ClaudeSessionModel? {
        guard state.provider == .claude,
              let sessionId = state.sessionId else {
            return nil
        }
        var model = ClaudeSessionModel(sessionId: sessionId)
        model.projectName = state.projectName
        model.gitBranch = state.gitBranch
        model.model = state.model
        model.turnCount = state.turnCount
        model.tokens = state.tokens
        model.startedAt = state.startedAt.map { Date(timeIntervalSince1970: $0) }
        model.lastEventAt = state.lastEventAt.map { Date(timeIntervalSince1970: $0) }
        model.lastToolName = state.lastToolName
        model.pendingToolUse = state.pendingToolUse ?? false
        model.lastAssistantStopReason = state.lastAssistantStopReason
        model.sawPermissionRequest = state.sawPermissionRequest ?? false
        model.lastInboundAwaitsModel = state.lastInboundAwaitsModel ?? false
        return model
    }

    // MARK: - Private helpers

    private struct Rate {
        var input: Double       // USD per 1M input tokens
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }

    // Deliberately tiny table keyed by model-family prefix. Unknown prefixes
    // (including claude-fable) return nil so cost is never fabricated.
    private static func pricing(for model: String) -> Rate? {
        // Order matters: match the more specific "sonnet-5" before "sonnet-4".
        if model.hasPrefix("claude-opus-4") {
            return Rate(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)
        }
        if model.hasPrefix("claude-sonnet-5") {
            return Rate(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
        }
        if model.hasPrefix("claude-sonnet-4") {
            return Rate(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
        }
        if model.hasPrefix("claude-haiku") {
            return Rate(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)
        }
        return nil
    }
}
