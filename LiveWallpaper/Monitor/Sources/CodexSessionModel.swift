import Foundation

struct CodexSessionModel: Sendable {
    private(set) var sessionId: String?
    private(set) var projectName: String?
    private(set) var gitBranch: String?
    private(set) var model: String?
    private(set) var turnCount = 0
    private(set) var tokens: MonitorTokenTotals = .zero
    private(set) var lastEventAt: Date?
    private(set) var lastToolName: String?
    private(set) var startedAt: Date?
    private(set) var lastTerminalEventIsTaskComplete = false
    private(set) var cwd: String?

    // v2 Fleet raw material.
    private(set) var lastUsageInput: Int?
    private(set) var lastUsageCacheRead: Int?
    private(set) var recentEventTimes: [Double] = []
    private(set) var recentTools: [MonitorAgentToolEvent] = []

    private var pendingApprovalAt: Date?
    private var lastApprovalClearAt: Date?
    private var lastStatusEventAt: Date?

    var pendingApproval: Bool {
        pendingApprovalAt != nil
    }

    mutating func ingest(_ lineData: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: lineData),
              let line = object as? [String: Any] else {
            return
        }
        ingest(decodedLine: line)
    }

    mutating func ingest(decodedLine line: [String: Any]) {
        let payload = line["payload"] as? [String: Any] ?? [:]
        let timestamp = Self.timestamp(from: line, payload: payload)
        if let timestamp {
            markFresh(at: timestamp)
            recentEventTimes.append(timestamp.timeIntervalSince1970)
            if recentEventTimes.count > MonitorFleetSignalDeriver.recentEventCap * 2 {
                recentEventTimes = Array(recentEventTimes.suffix(MonitorFleetSignalDeriver.recentEventCap))
            }
        }

        if let discoveredModel = Self.discoveredModel(in: payload) {
            model = discoveredModel
        }

        guard let lineType = Self.stringValue(line["type"]) else { return }
        switch lineType {
        case "session_meta":
            ingestSessionMeta(payload)
        case "event_msg":
            ingestEvent(payload, timestamp: timestamp)
        case "response_item":
            ingestResponseItem(payload, timestamp: timestamp)
        default:
            break
        }
    }

    func status(
        now: Date,
        processAlive: Bool,
        freshnessTimeout: TimeInterval = 180
    ) -> MonitorAgentStatus {
        guard let lastEventAt else { return .unknown }
        let age = max(0, now.timeIntervalSince(lastEventAt))

        if pendingApproval && processAlive {
            return .needsInput
        }
        if age < 15, !lastTerminalEventIsTaskComplete {
            return .running
        }
        if lastTerminalEventIsTaskComplete && processAlive {
            return .idle
        }
        if age >= freshnessTimeout {
            return processAlive ? .idle : .ended
        }
        return .unknown
    }

    func contextUsedPercent() -> Double? {
        MonitorFleetSignalDeriver.contextUsedPercent(
            lastInputTokens: lastUsageInput,
            lastCacheReadTokens: lastUsageCacheRead,
            model: model
        )
    }

    var worktreeName: String? { MonitorWorktree.name(fromCwd: cwd) }

    func sessionState(
        now: Date,
        processAlive: Bool,
        fallbackSessionId: String,
        fallbackProjectName: String
    ) -> MonitorAgentSessionState? {
        guard let lastEventAt else { return nil }
        let resolvedSessionId = sessionId ?? fallbackSessionId
        let currentStatus = status(now: now, processAlive: processAlive)
        var state = MonitorAgentSessionState(
            id: "codex:\(resolvedSessionId)",
            provider: .codex,
            projectName: projectName ?? fallbackProjectName,
            status: currentStatus,
            statusDetail: lastToolName,
            model: model,
            gitBranch: gitBranch,
            startedAt: startedAt?.timeIntervalSince1970,
            lastEventAt: lastEventAt.timeIntervalSince1970,
            processAlive: processAlive,
            turnCount: turnCount,
            tokens: tokens,
            costUSD: nil
        )
        state.recentEventTimes = MonitorFleetSignalDeriver.trimmedEventTimes(recentEventTimes)
        state.recentTools = MonitorFleetSignalDeriver.trimmedTools(recentTools)
        state.contextUsedPercent = contextUsedPercent()
        state.warning = MonitorFleetSignalDeriver.warning(
            recentTools: recentTools,
            status: currentStatus,
            processAlive: processAlive,
            lastEventAt: lastEventAt.timeIntervalSince1970,
            now: now.timeIntervalSince1970
        )
        state.worktreeName = worktreeName
        return state
    }

    func snapshotState() -> SessionAggregateState {
        SessionAggregateState(
            provider: .codex,
            sessionId: sessionId,
            projectName: projectName,
            gitBranch: gitBranch,
            model: model,
            turnCount: turnCount,
            tokens: tokens,
            startedAt: startedAt?.timeIntervalSince1970,
            lastEventAt: lastEventAt?.timeIntervalSince1970,
            lastToolName: lastToolName,
            pendingApprovalAt: pendingApprovalAt?.timeIntervalSince1970,
            lastApprovalClearAt: lastApprovalClearAt?.timeIntervalSince1970,
            lastStatusEventAt: lastStatusEventAt?.timeIntervalSince1970,
            lastTerminalEventIsTaskComplete: lastTerminalEventIsTaskComplete
        )
    }

    static func restore(from state: SessionAggregateState) -> CodexSessionModel? {
        guard state.provider == .codex else { return nil }
        var model = CodexSessionModel()
        model.sessionId = state.sessionId
        model.projectName = state.projectName
        model.gitBranch = state.gitBranch
        model.model = state.model
        model.turnCount = state.turnCount
        model.tokens = state.tokens
        model.startedAt = state.startedAt.map { Date(timeIntervalSince1970: $0) }
        model.lastEventAt = state.lastEventAt.map { Date(timeIntervalSince1970: $0) }
        model.lastToolName = state.lastToolName
        model.pendingApprovalAt = state.pendingApprovalAt.map { Date(timeIntervalSince1970: $0) }
        model.lastApprovalClearAt = state.lastApprovalClearAt.map { Date(timeIntervalSince1970: $0) }
        model.lastStatusEventAt = state.lastStatusEventAt.map { Date(timeIntervalSince1970: $0) }
        model.lastTerminalEventIsTaskComplete = state.lastTerminalEventIsTaskComplete ?? false
        return model
    }

    // MARK: - Ingestion

    private mutating func ingestSessionMeta(_ payload: [String: Any]) {
        sessionId = Self.stringValue(payload["id"]) ?? Self.stringValue(payload["session_id"]) ?? sessionId

        if let cwd = Self.stringValue(payload["cwd"]) {
            self.cwd = cwd
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if !name.isEmpty {
                projectName = name
            }
        }

        if let git = payload["git"] as? [String: Any] {
            gitBranch = Self.stringValue(git["branch"]) ?? gitBranch
        }
    }

    private mutating func ingestEvent(_ payload: [String: Any], timestamp: Date?) {
        guard let payloadType = Self.stringValue(payload["type"]) else { return }

        switch payloadType {
        case "task_started":
            turnCount += 1
            if let timestamp {
                clearPendingApproval(at: timestamp)
                markTerminal(false, at: timestamp)
            }
        case "task_complete":
            if let timestamp {
                clearPendingApproval(at: timestamp)
                markTerminal(true, at: timestamp)
            }
        case "agent_message", "user_message":
            if let timestamp {
                clearPendingApproval(at: timestamp)
                if payloadType == "user_message" {
                    markTerminal(false, at: timestamp)
                }
            }
        case "token_count":
            ingestTokenCount(payload)
        default:
            if Self.isApprovalRequest(payloadType) {
                if let timestamp {
                    markPendingApproval(at: timestamp)
                    markTerminal(false, at: timestamp)
                }
            } else if Self.isApprovalResolution(payloadType), let timestamp {
                clearPendingApproval(at: timestamp)
            }
        }
    }

    private mutating func ingestResponseItem(_ payload: [String: Any], timestamp: Date?) {
        guard let toolName = Self.toolName(from: payload) else { return }
        lastToolName = toolName
        // Codex exposes no metadata-only success/failure marker on the call event
        // (exit status lives in the tool output we deliberately never read), so ok
        // stays nil rather than guessing.
        let at = timestamp?.timeIntervalSince1970 ?? lastEventAt?.timeIntervalSince1970 ?? 0
        recentTools.append(MonitorAgentToolEvent(name: toolName, at: at, ok: nil))
        if recentTools.count > MonitorFleetSignalDeriver.recentToolCap * 3 {
            recentTools = Array(recentTools.suffix(MonitorFleetSignalDeriver.recentToolCap * 3))
        }
        if let timestamp {
            markTerminal(false, at: timestamp)
        }
    }

    private mutating func ingestTokenCount(_ payload: [String: Any]) {
        if let info = payload["info"] as? [String: Any] {
            if let total = info["total_token_usage"] as? [String: Any] {
                tokens = Self.tokenTotals(from: total)
                recordLastUsage(from: total)
                return
            }
            if let last = info["last_token_usage"] as? [String: Any] {
                tokens = tokens + Self.tokenTotals(from: last)
                recordLastUsage(from: last)
                return
            }
        }

        if let total = payload["total_token_usage"] as? [String: Any] {
            tokens = Self.tokenTotals(from: total)
            recordLastUsage(from: total)
        } else if let last = payload["last_token_usage"] as? [String: Any] {
            tokens = tokens + Self.tokenTotals(from: last)
            recordLastUsage(from: last)
        }
    }

    /// Context load for Codex = the latest token_count's input + cached-input.
    private mutating func recordLastUsage(from usage: [String: Any]) {
        let totals = Self.tokenTotals(from: usage)
        lastUsageInput = totals.input
        lastUsageCacheRead = totals.cacheRead
    }

    // MARK: - State helpers

    private mutating func markFresh(at date: Date) {
        if startedAt == nil {
            startedAt = date
        }
        if lastEventAt == nil || date >= (lastEventAt ?? date) {
            lastEventAt = date
        }
    }

    private mutating func markTerminal(_ isTaskComplete: Bool, at date: Date) {
        guard lastStatusEventAt == nil || date >= (lastStatusEventAt ?? date) else { return }
        lastStatusEventAt = date
        lastTerminalEventIsTaskComplete = isTaskComplete
    }

    private mutating func markPendingApproval(at date: Date) {
        if let lastApprovalClearAt, date <= lastApprovalClearAt {
            return
        }
        pendingApprovalAt = date
    }

    private mutating func clearPendingApproval(at date: Date) {
        if lastApprovalClearAt == nil || date >= (lastApprovalClearAt ?? date) {
            lastApprovalClearAt = date
        }
        if let pendingApprovalAt, date >= pendingApprovalAt {
            self.pendingApprovalAt = nil
        }
    }

    // MARK: - Parsing helpers

    private static func timestamp(from line: [String: Any], payload: [String: Any]) -> Date? {
        let value = stringValue(line["timestamp"]) ?? stringValue(payload["timestamp"])
        guard let value else { return nil }
        return parseTimestamp(value)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func discoveredModel(in payload: [String: Any]) -> String? {
        if let model = stringValue(payload["model"]) {
            return model
        }
        if let collaboration = payload["collaboration_mode"] as? [String: Any],
           let settings = collaboration["settings"] as? [String: Any],
           let model = stringValue(settings["model"]) {
            return model
        }
        if let info = payload["info"] as? [String: Any],
           let model = stringValue(info["model"]) {
            return model
        }
        return nil
    }

    private static func toolName(from payload: [String: Any]) -> String? {
        guard let payloadType = stringValue(payload["type"]) else { return nil }
        if payloadType == "local_shell_call" {
            return "shell"
        }
        if payloadType == "web_search_call" {
            return "web_search"
        }
        if let name = stringValue(payload["name"]) {
            return sanitizedToolName(name)
        }
        if payloadType.hasSuffix("_call") {
            return sanitizedToolName(String(payloadType.dropLast(5)))
        }
        return nil
    }

    private static func sanitizedToolName(_ value: String) -> String? {
        // Shared allowlist + length-cap discipline (identical to the Claude path);
        // the Codex-specific alias is applied on top.
        guard let name = MonitorFleetSignalDeriver.sanitizedToolName(value) else { return nil }
        if name == "exec_command" {
            return "shell"
        }
        return name
    }

    private static func isApprovalRequest(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        guard lowercased.contains("approval") else { return false }
        return lowercased.contains("request") || !isApprovalResolution(value)
    }

    private static func isApprovalResolution(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.contains("response")
            || lowercased.contains("approved")
            || lowercased.contains("denied")
            || lowercased.contains("rejected")
            || lowercased.contains("resolved")
    }

    private static func tokenTotals(from usage: [String: Any]) -> MonitorTokenTotals {
        MonitorTokenTotals(
            input: intValue(usage["input_tokens"]) ?? intValue(usage["input"]) ?? 0,
            output: intValue(usage["output_tokens"]) ?? intValue(usage["output"]) ?? 0,
            cacheRead: intValue(usage["cached_input_tokens"])
                ?? intValue(usage["cache_read_tokens"])
                ?? intValue(usage["cacheRead"])
                ?? 0,
            cacheWrite: intValue(usage["cache_write_tokens"])
                ?? intValue(usage["cache_creation_input_tokens"])
                ?? intValue(usage["cacheWrite"])
                ?? 0
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue
        }
        if let string = stringValue(value) {
            return Int(string)
        }
        return nil
    }
}
