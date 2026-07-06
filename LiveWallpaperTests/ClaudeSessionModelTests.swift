import Foundation
import Testing
@testable import LiveWallpaper

@Suite("ClaudeSessionModel: transcript folding + classification")
struct ClaudeSessionModelTests {

    // MARK: - Fixtures

    private static let base = Date(timeIntervalSince1970: 1_783_000_000)

    /// Build one JSONL line as Data via the real parser, so tests exercise the
    /// same decode path as production. All values are synthetic.
    private func line(_ dict: [String: Any]) -> ClaudeTranscriptLine {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return ClaudeTranscriptLine(data: data)!
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func assistantToolUse(tool: String, at date: Date, model: String = "claude-opus-4-8") -> ClaudeTranscriptLine {
        line([
            "type": "assistant", "isSidechain": false, "timestamp": iso(date),
            "sessionId": "s1", "cwd": "/Users/me/proj",
            "message": [
                "role": "assistant", "model": model, "stop_reason": "tool_use",
                "content": [["type": "tool_use", "name": tool]],
                "usage": ["input_tokens": 100, "output_tokens": 20,
                          "cache_read_input_tokens": 300, "cache_creation_input_tokens": 40]
            ]
        ])
    }

    private func assistantEndTurn(at date: Date, model: String = "claude-opus-4-8") -> ClaudeTranscriptLine {
        line([
            "type": "assistant", "isSidechain": false, "timestamp": iso(date),
            "sessionId": "s1", "cwd": "/Users/me/proj",
            "message": [
                "role": "assistant", "model": model, "stop_reason": "end_turn",
                "content": [["type": "text", "text": "redacted"]],
                "usage": ["input_tokens": 10, "output_tokens": 5,
                          "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]
            ]
        ])
    }

    private func toolResult(at date: Date) -> ClaudeTranscriptLine {
        line([
            "type": "user", "isSidechain": false, "timestamp": iso(date), "sessionId": "s1",
            "message": ["role": "user", "content": [["type": "tool_result", "content": "redacted"]]]
        ])
    }

    private func userPrompt(at date: Date) -> ClaudeTranscriptLine {
        line([
            "type": "user", "isSidechain": false, "timestamp": iso(date), "sessionId": "s1",
            "message": ["role": "user", "content": "please do the thing"]
        ])
    }

    // MARK: - Classification rows

    @Test("running: fresh assistant tool_use with pending tool → .running, detail = tool name only")
    func runningWithTool() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantToolUse(tool: "Bash", at: now))

        #expect(model.status(now: now.addingTimeInterval(2), processAlive: true) == .running)
        #expect(model.statusDetail(now: now.addingTimeInterval(2), processAlive: true) == "Bash")
    }

    @Test("statusDetail never leaks anything but the tool name")
    func statusDetailIsToolNameOnly() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantToolUse(tool: "Edit", at: now))
        let detail = model.statusDetail(now: now.addingTimeInterval(1), processAlive: true)
        #expect(detail == "Edit")
    }

    @Test("end_turn + process alive → .idle (no detail)")
    func endTurnAliveIsIdle() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantEndTurn(at: now))
        // Past the fresh window so the running rule doesn't fire.
        let later = now.addingTimeInterval(30)
        #expect(model.status(now: later, processAlive: true) == .idle)
        #expect(model.statusDetail(now: later, processAlive: true) == nil)
    }

    @Test("end_turn + process dead → .ended")
    func endTurnDeadIsEnded() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantEndTurn(at: now))
        let later = now.addingTimeInterval(30)
        #expect(model.status(now: later, processAlive: false) == .ended)
    }

    @Test("permission system line + alive → .needsInput")
    func permissionIsNeedsInput() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantToolUse(tool: "Bash", at: now))
        model.ingest(line([
            "type": "system", "isSidechain": false, "timestamp": iso(now.addingTimeInterval(1)),
            "sessionId": "s1", "subtype": "permission_request",
            "message": ["content": "requesting permission to run Bash"]
        ]))
        #expect(model.sawPermissionRequest == true)
        #expect(model.status(now: now.addingTimeInterval(2), processAlive: true) == .needsInput)
    }

    @Test("permission cleared by a newer user line")
    func permissionClearedByNewerUserLine() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(line([
            "type": "system", "isSidechain": false, "timestamp": iso(now),
            "sessionId": "s1", "message": ["content": "approval needed"]
        ]))
        #expect(model.sawPermissionRequest == true)
        model.ingest(userPrompt(at: now.addingTimeInterval(1)))
        #expect(model.sawPermissionRequest == false)
        #expect(model.status(now: now.addingTimeInterval(2), processAlive: true) != .needsInput)
    }

    @Test("stale beyond freshnessTimeout + dead → .ended")
    func staleDeadIsEnded() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantToolUse(tool: "Bash", at: now))
        let farLater = now.addingTimeInterval(1000)
        #expect(model.status(now: farLater, processAlive: false) == .ended)
    }

    @Test("stale beyond freshnessTimeout + alive → .idle")
    func staleAliveIsIdle() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantToolUse(tool: "Bash", at: now))
        let farLater = now.addingTimeInterval(1000)
        #expect(model.status(now: farLater, processAlive: true) == .idle)
    }

    @Test("fresh tool_result hands control to model → .running")
    func freshToolResultIsRunning() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantToolUse(tool: "Bash", at: now))
        model.ingest(toolResult(at: now.addingTimeInterval(1)))
        #expect(model.pendingToolUse == false)
        #expect(model.status(now: now.addingTimeInterval(2), processAlive: true) == .running)
    }

    // MARK: - Turn counting

    @Test("sidechain lines excluded from turn count but update freshness")
    func sidechainExcludedFromTurns() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(userPrompt(at: now))                                  // +1
        model.ingest(line([                                                 // sidechain, no +1
            "type": "user", "isSidechain": true, "timestamp": iso(now.addingTimeInterval(5)),
            "sessionId": "s1", "message": ["role": "user", "content": "subagent prompt"]
        ]))
        #expect(model.turnCount == 1)
        // Freshness still advanced by the sidechain line's newer timestamp.
        #expect(model.lastEventAt == now.addingTimeInterval(5))
    }

    @Test("tool_result user lines are not counted as turns")
    func toolResultNotCountedAsTurn() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(userPrompt(at: now))                 // +1
        model.ingest(toolResult(at: now.addingTimeInterval(1)))  // +0
        model.ingest(toolResult(at: now.addingTimeInterval(2)))  // +0
        #expect(model.turnCount == 1)
    }

    @Test("multiple real prompts increment turn count")
    func multiplePromptsCounted() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(userPrompt(at: now))
        model.ingest(assistantEndTurn(at: now.addingTimeInterval(1)))
        model.ingest(userPrompt(at: now.addingTimeInterval(2)))
        #expect(model.turnCount == 2)
    }

    // MARK: - Token aggregation

    @Test("token totals sum input/output/cacheRead/cacheWrite across assistant lines")
    func tokenAggregation() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantToolUse(tool: "Bash", at: now))              // 100/20/300/40
        model.ingest(assistantToolUse(tool: "Read", at: now.addingTimeInterval(1)))  // +100/20/300/40
        #expect(model.tokens == MonitorTokenTotals(input: 200, output: 40, cacheRead: 600, cacheWrite: 80))
    }

    @Test("user and system lines contribute no tokens")
    func nonAssistantLinesNoTokens() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(userPrompt(at: now))
        model.ingest(toolResult(at: now.addingTimeInterval(1)))
        #expect(model.tokens == .zero)
    }

    // MARK: - Display fields

    @Test("projectName is last path component of cwd; model is last assistant model")
    func displayFields() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantToolUse(tool: "Bash", at: now, model: "claude-sonnet-4-5"))
        model.ingest(assistantEndTurn(at: now.addingTimeInterval(1), model: "claude-opus-4-8"))
        #expect(model.projectName == "proj")
        #expect(model.model == "claude-opus-4-8")
    }

    // MARK: - Cost

    @Test("known model prefixes produce a positive cost")
    func knownModelCost() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantToolUse(tool: "Bash", at: now, model: "claude-opus-4-8"))
        let cost = model.costUSD()
        #expect(cost != nil)
        #expect((cost ?? 0) > 0)
    }

    @Test("unknown model (claude-fable) → nil cost, never guessed")
    func unknownModelNilCost() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        model.ingest(assistantToolUse(tool: "Bash", at: now, model: "claude-fable-1"))
        #expect(model.costUSD() == nil)
    }

    @Test("opus priced above sonnet for identical token mix")
    func opusPricierThanSonnet() {
        let now = Self.base
        var opus = ClaudeSessionModel(sessionId: "o")
        opus.ingest(assistantToolUse(tool: "Bash", at: now, model: "claude-opus-4-8"))
        var sonnet = ClaudeSessionModel(sessionId: "s")
        sonnet.ingest(assistantToolUse(tool: "Bash", at: now, model: "claude-sonnet-4-5"))
        #expect((opus.costUSD() ?? 0) > (sonnet.costUSD() ?? 0))
    }

    // MARK: - Robustness

    @Test("unknown line types decode without throwing and only touch freshness")
    func unknownLineTypesAreNoOps() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let now = Self.base
        for t in ["queue-operation", "attachment", "last-prompt", "custom-title"] {
            model.ingest(line(["type": t, "timestamp": iso(now), "sessionId": "s1"]))
        }
        #expect(model.turnCount == 0)
        #expect(model.tokens == .zero)
        #expect(model.lastEventAt == now)
    }

    @Test("snapshot emits id \"claude:<sessionId>\" and privacy-safe fields")
    func snapshotShape() {
        var model = ClaudeSessionModel(sessionId: "abc")
        let now = Self.base
        model.ingest(assistantToolUse(tool: "Bash", at: now))
        let snap = model.snapshot(now: now.addingTimeInterval(1), processAlive: true)
        #expect(snap.id == "claude:abc")
        #expect(snap.provider == .claude)
        #expect(snap.statusDetail == "Bash")
    }
}
