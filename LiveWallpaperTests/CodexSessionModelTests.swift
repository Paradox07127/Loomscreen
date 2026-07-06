import Foundation
import Testing
@testable import LiveWallpaper

@Suite("CodexSessionModel")
struct CodexSessionModelTests {
    @Test("Parses session_meta identity and project fields")
    func parsesSessionMeta() {
        var model = CodexSessionModel()

        model.ingest(Self.line(
            timestamp: "1970-01-01T00:00:10.000Z",
            type: "session_meta",
            payload: """
            {
              "id": "session-alpha",
              "cwd": "/tmp/ProjectAlpha",
              "git": { "branch": "feature/monitor" },
              "model": "gpt-synthetic"
            }
            """
        ))

        #expect(model.sessionId == "session-alpha")
        #expect(model.projectName == "ProjectAlpha")
        #expect(model.gitBranch == "feature/monitor")
        #expect(model.model == "gpt-synthetic")
        #expect(model.startedAt?.timeIntervalSince1970 == 10)
        #expect(model.lastEventAt?.timeIntervalSince1970 == 10)
    }

    @Test("Classifies task_started as running and task_complete as idle while Codex is alive")
    func taskTransitions() {
        var model = CodexSessionModel()
        model.ingest(Self.line(
            timestamp: "1970-01-01T00:00:20.000Z",
            type: "event_msg",
            payload: #"{"type": "task_started"}"#
        ))

        #expect(model.turnCount == 1)
        #expect(model.status(now: Date(timeIntervalSince1970: 25), processAlive: true) == .running)

        model.ingest(Self.line(
            timestamp: "1970-01-01T00:00:30.000Z",
            type: "event_msg",
            payload: #"{"type": "task_complete"}"#
        ))

        #expect(model.status(now: Date(timeIntervalSince1970: 31), processAlive: true) == .idle)
        #expect(model.status(now: Date(timeIntervalSince1970: 240), processAlive: false) == .ended)
    }

    @Test("Approval request makes a live session need input until a newer agent event")
    func approvalNeedsInput() {
        var model = CodexSessionModel()
        model.ingest(Self.line(
            timestamp: "1970-01-01T00:01:00.000Z",
            type: "event_msg",
            payload: #"{"type": "task_started"}"#
        ))
        model.ingest(Self.line(
            timestamp: "1970-01-01T00:01:05.000Z",
            type: "event_msg",
            payload: #"{"type": "exec_approval_request"}"#
        ))

        #expect(model.pendingApproval == true)
        #expect(model.status(now: Date(timeIntervalSince1970: 70), processAlive: true) == .needsInput)

        model.ingest(Self.line(
            timestamp: "1970-01-01T00:01:15.000Z",
            type: "event_msg",
            payload: #"{"type": "agent_message"}"#
        ))

        #expect(model.pendingApproval == false)
        #expect(model.status(now: Date(timeIntervalSince1970: 76), processAlive: true) == .running)
    }

    @Test("Aggregates token_count totals from total_token_usage")
    func aggregatesTokenTotals() {
        var model = CodexSessionModel()
        model.ingest(Self.line(
            timestamp: "1970-01-01T00:02:00.000Z",
            type: "event_msg",
            payload: """
            {
              "type": "token_count",
              "info": {
                "total_token_usage": {
                  "input_tokens": 10,
                  "cached_input_tokens": 4,
                  "output_tokens": 6,
                  "reasoning_output_tokens": 2,
                  "total_tokens": 22
                }
              }
            }
            """
        ))
        model.ingest(Self.line(
            timestamp: "1970-01-01T00:02:05.000Z",
            type: "event_msg",
            payload: """
            {
              "type": "token_count",
              "info": {
                "total_token_usage": {
                  "input_tokens": 20,
                  "cached_input_tokens": 5,
                  "output_tokens": 7
                }
              }
            }
            """
        ))

        #expect(model.tokens == MonitorTokenTotals(input: 20, output: 7, cacheRead: 5, cacheWrite: 0))
    }

    @Test("Unknown line types update freshness without changing terminal state")
    func unknownTypesUpdateFreshness() {
        var model = CodexSessionModel()
        model.ingest(Self.line(
            timestamp: "1970-01-01T00:03:00.000Z",
            type: "event_msg",
            payload: #"{"type": "task_complete"}"#
        ))
        model.ingest(Self.line(
            timestamp: "1970-01-01T00:03:10.000Z",
            type: "future_unknown_type",
            payload: #"{"type": "future_unknown_payload"}"#
        ))

        #expect(model.lastEventAt?.timeIntervalSince1970 == 190)
        #expect(model.status(now: Date(timeIntervalSince1970: 195), processAlive: true) == .idle)
    }

    @Test("Response item status detail uses only the tool name")
    func responseItemUsesToolNameOnly() {
        var model = CodexSessionModel()

        model.ingest(Self.line(
            timestamp: "1970-01-01T00:04:00.000Z",
            type: "response_item",
            payload: #"{"type": "function_call", "name": "shell", "arguments": "rm -rf synthetic-secret"}"#
        ))

        #expect(model.lastToolName == "shell")
    }

    private static func line(timestamp: String, type: String, payload: String) -> Data {
        Data(#"{"timestamp":"\#(timestamp)","type":"\#(type)","payload":\#(payload)}"#.utf8)
    }
}
