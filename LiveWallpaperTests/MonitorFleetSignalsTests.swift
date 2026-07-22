import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Monitor fleet signals")
struct MonitorFleetSignalsTests {

    @Test("context window resolves per family prefix and gpt-5 window")
    func contextWindowTable() {
        #expect(MonitorModelContextCatalog.contextWindow(for: "claude-opus-4-8") == 200_000)
        #expect(MonitorModelContextCatalog.contextWindow(for: "claude-sonnet-5") == 200_000)
        #expect(MonitorModelContextCatalog.contextWindow(for: "claude-fable-5") == 200_000)
        #expect(MonitorModelContextCatalog.contextWindow(for: "claude-haiku-4-5") == 200_000)
        #expect(MonitorModelContextCatalog.contextWindow(for: "gpt-5.5") == 272_000)
        #expect(MonitorModelContextCatalog.contextWindow(for: "codex-auto-review") == 272_000)
        #expect(MonitorModelContextCatalog.contextWindow(for: "opus") == 200_000)
    }

    @Test("unknown model → nil context window (never guessed)")
    func unknownModelWindowNil() {
        #expect(MonitorModelContextCatalog.contextWindow(for: "mystery-model-9") == nil)
        #expect(MonitorModelContextCatalog.contextWindow(for: nil) == nil)
    }

    @Test("contextUsedPercent = (input + cacheRead) ÷ window, clamped")
    func contextPercentMath() {
        let half = MonitorFleetSignalDeriver.contextUsedPercent(
            lastInputTokens: 40_000, lastCacheReadTokens: 60_000, model: "claude-opus-4-8"
        )
        #expect(half == 0.5)

        let clamped = MonitorFleetSignalDeriver.contextUsedPercent(
            lastInputTokens: 500_000, lastCacheReadTokens: 0, model: "claude-opus-4-8"
        )
        #expect(clamped == 1)

        let codex = MonitorFleetSignalDeriver.contextUsedPercent(
            lastInputTokens: 136_000, lastCacheReadTokens: 0, model: "gpt-5.5"
        )
        #expect(codex == 0.5)
    }

    @Test("contextUsedPercent nil for unknown model or no usage seen")
    func contextPercentNil() {
        #expect(MonitorFleetSignalDeriver.contextUsedPercent(
            lastInputTokens: 100, lastCacheReadTokens: 100, model: "mystery"
        ) == nil)
        #expect(MonitorFleetSignalDeriver.contextUsedPercent(
            lastInputTokens: nil, lastCacheReadTokens: nil, model: "claude-opus-4-8"
        ) == nil)
    }

    @Test("Claude model derives contextUsedPercent from last usage-bearing event")
    func claudeContextFromTranscript() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let base = Date(timeIntervalSince1970: 1_783_000_000)
        model.ingest(assistant(tool: "Bash", at: base, input: 190_000, cacheRead: 0, model: "claude-opus-4-8"))
        model.ingest(assistant(tool: "Read", at: base.addingTimeInterval(1), input: 20_000, cacheRead: 30_000, model: "claude-opus-4-8"))
        #expect(model.contextUsedPercent() == 0.25)
    }

    @Test("toolLoop fires on 8 consecutive same-name tools within 10 min")
    func toolLoopDetected() {
        let base = 1_000.0
        let tools = (0..<8).map { MonitorAgentToolEvent(name: "Bash", at: base + Double($0) * 30, ok: true) }
        #expect(MonitorFleetSignalDeriver.isToolLoop(tools))
        let warning = MonitorFleetSignalDeriver.warning(
            recentTools: tools, status: .running, processAlive: true,
            lastEventAt: base + 210, now: base + 215
        )
        #expect(warning == "toolLoop")
    }

    @Test("no loop when names differ or run is short or window too wide")
    func toolLoopNegatives() {
        let base = 1_000.0
        let mixed = (0..<8).map { MonitorAgentToolEvent(name: $0 % 2 == 0 ? "Bash" : "Read", at: base + Double($0), ok: true) }
        #expect(!MonitorFleetSignalDeriver.isToolLoop(mixed))
        let short = (0..<7).map { MonitorAgentToolEvent(name: "Bash", at: base + Double($0), ok: true) }
        #expect(!MonitorFleetSignalDeriver.isToolLoop(short))
        let wide = (0..<8).map { MonitorAgentToolEvent(name: "Bash", at: base + Double($0) * 120, ok: true) }
        #expect(!MonitorFleetSignalDeriver.isToolLoop(wide))
    }

    @Test("stale fires when running + alive + no event > 5 min")
    func staleDetected() {
        let now = 10_000.0
        let warning = MonitorFleetSignalDeriver.warning(
            recentTools: [], status: .running, processAlive: true,
            lastEventAt: now - 400, now: now
        )
        #expect(warning == "stale")
    }

    @Test("no stale when idle, dead, or recently active; loop precedes stale")
    func staleNegativesAndPrecedence() {
        let now = 10_000.0
        #expect(MonitorFleetSignalDeriver.warning(
            recentTools: [], status: .idle, processAlive: true, lastEventAt: now - 400, now: now
        ) == nil)
        #expect(MonitorFleetSignalDeriver.warning(
            recentTools: [], status: .running, processAlive: true, lastEventAt: now - 60, now: now
        ) == nil)
        #expect(MonitorFleetSignalDeriver.warning(
            recentTools: [], status: .running, processAlive: false, lastEventAt: now - 400, now: now
        ) == nil)
        let loop = (0..<8).map { MonitorAgentToolEvent(name: "Bash", at: now - 300 + Double($0), ok: true) }
        #expect(MonitorFleetSignalDeriver.warning(
            recentTools: loop, status: .running, processAlive: true, lastEventAt: now - 400, now: now
        ) == "toolLoop")
    }

    @Test("waitSince stamps flip into needsInput, carries, then clears")
    func waitSinceLifecycle() {
        var tracker = MonitorFleetWaitTracker()
        #expect(tracker.waitSince(sessionID: "s", status: .running, eventTime: 100) == nil)
        #expect(tracker.waitSince(sessionID: "s", status: .needsInput, eventTime: 200) == 200)
        #expect(tracker.waitSince(sessionID: "s", status: .needsInput, eventTime: 260) == 200)
        #expect(tracker.waitSince(sessionID: "s", status: .running, eventTime: 300) == nil)
        #expect(tracker.waitSince(sessionID: "s", status: .needsInput, eventTime: 400) == 400)
    }

    @Test("waitTracker forgets sessions dropped from the live set")
    func waitTrackerRetention() {
        var tracker = MonitorFleetWaitTracker()
        _ = tracker.waitSince(sessionID: "a", status: .needsInput, eventTime: 100)
        _ = tracker.waitSince(sessionID: "b", status: .needsInput, eventTime: 100)
        tracker.retainOnly(["a"])
        #expect(tracker.waitSince(sessionID: "b", status: .needsInput, eventTime: 999) == 999)
        #expect(tracker.waitSince(sessionID: "a", status: .needsInput, eventTime: 999) == 100)
    }

    @Test("recentTools marks ok=false on the paired tool_result is_error")
    func recentToolsErrorPairing() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let base = Date(timeIntervalSince1970: 1_783_000_000)
        model.ingest(assistant(tool: "Bash", at: base, input: 10, cacheRead: 0))
        model.ingest(toolResult(at: base.addingTimeInterval(1), isError: true))
        model.ingest(assistant(tool: "Read", at: base.addingTimeInterval(2), input: 10, cacheRead: 0))
        model.ingest(toolResult(at: base.addingTimeInterval(3), isError: false))

        let snap = model.snapshot(now: base.addingTimeInterval(4), processAlive: true)
        let tools = snap.recentTools ?? []
        #expect(tools.count == 2)
        #expect(tools[0].name == "Bash")
        #expect(tools[0].ok == false)
        #expect(tools[1].name == "Read")
        #expect(tools[1].ok == true)
    }

    @Test("recentEventTimes capped at 60, ascending")
    func recentEventTimesCap() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let base = Date(timeIntervalSince1970: 1_783_000_000)
        for i in 0..<100 {
            model.ingest(assistant(tool: "Bash", at: base.addingTimeInterval(Double(i)), input: 1, cacheRead: 0))
        }
        let snap = model.snapshot(now: base.addingTimeInterval(200), processAlive: true)
        let times = snap.recentEventTimes ?? []
        #expect(times.count == 60)
        #expect(times == times.sorted())
        #expect(times.last == base.addingTimeInterval(99).timeIntervalSince1970)
    }

    @Test("recentTools surfaced tail capped at 8")
    func recentToolsCap() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let base = Date(timeIntervalSince1970: 1_783_000_000)
        for i in 0..<20 {
            model.ingest(assistant(tool: "Bash", at: base.addingTimeInterval(Double(i)), input: 1, cacheRead: 0))
        }
        let snap = model.snapshot(now: base.addingTimeInterval(30), processAlive: true)
        #expect((snap.recentTools?.count ?? 0) == 8)
    }

    @Test("worktreeName extracts the segment after .claude/worktrees, else nil")
    func worktreeExtraction() {
        #expect(MonitorWorktree.name(fromCwd: "/Users/me/proj/.claude/worktrees/feature-x") == "feature-x")
        #expect(MonitorWorktree.name(fromCwd: "/Users/me/proj/.claude/worktrees/feature-x/src/deep") == "feature-x")
        #expect(MonitorWorktree.name(fromCwd: "/Users/me/proj/src") == nil)
        #expect(MonitorWorktree.name(fromCwd: "/Users/me/worktrees/x") == nil)
        #expect(MonitorWorktree.name(fromCwd: nil) == nil)
    }

    @Test("Claude snapshot carries worktreeName from cwd metadata")
    func claudeSnapshotWorktree() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let base = Date(timeIntervalSince1970: 1_783_000_000)
        model.ingest(line([
            "type": "assistant", "isSidechain": false, "timestamp": iso(base),
            "sessionId": "s1", "cwd": "/Users/me/LiveWallpaper/.claude/worktrees/monitor-v2",
            "message": [
                "role": "assistant", "model": "claude-opus-4-8", "stop_reason": "tool_use",
                "content": [["type": "tool_use", "name": "Bash"]],
                "usage": ["input_tokens": 10, "output_tokens": 1, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]
            ]
        ]))
        let snap = model.snapshot(now: base.addingTimeInterval(1), processAlive: true)
        #expect(snap.worktreeName == "monitor-v2")
    }

    private func line(_ dict: [String: Any]) -> ClaudeTranscriptLine {
        ClaudeTranscriptLine(data: try! JSONSerialization.data(withJSONObject: dict))!
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func assistant(tool: String, at date: Date, input: Int, cacheRead: Int, model: String = "claude-opus-4-8") -> ClaudeTranscriptLine {
        line([
            "type": "assistant", "isSidechain": false, "timestamp": iso(date),
            "sessionId": "s1", "cwd": "/Users/me/proj",
            "message": [
                "role": "assistant", "model": model, "stop_reason": "tool_use",
                "content": [["type": "tool_use", "name": tool]],
                "usage": ["input_tokens": input, "output_tokens": 5,
                          "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": 0]
            ]
        ])
    }

    private func toolResult(at date: Date, isError: Bool) -> ClaudeTranscriptLine {
        line([
            "type": "user", "isSidechain": false, "timestamp": iso(date), "sessionId": "s1",
            "message": ["role": "user", "content": [["type": "tool_result", "content": "redacted", "is_error": isError]]]
        ])
    }
}
