import Foundation
import Testing
@testable import LiveWallpaper

@Suite("MonitorTailCursorStore")
struct MonitorTailCursorStoreTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitorTailCursorStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func storageURL(in directory: URL) -> URL {
        directory.appendingPathComponent("MonitorTailCursors.json", isDirectory: false)
    }

    @Test("persists and loads cursor plus aggregate state from injected directory")
    func persistLoadRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/example/.claude/projects/project/session.jsonl")
        let cursor = TailCursorState(inode: 42, size: 1024, offset: 512)
        let aggregate = SessionAggregateState(
            provider: .claude,
            sessionId: "session",
            projectName: "project",
            gitBranch: "main",
            model: "claude-sonnet-4-5",
            turnCount: 3,
            tokens: MonitorTokenTotals(input: 10, output: 20, cacheRead: 30, cacheWrite: 40),
            startedAt: 100,
            lastEventAt: 200,
            lastToolName: "Bash",
            pendingToolUse: true,
            lastAssistantStopReason: "tool_use",
            sawPermissionRequest: false,
            lastInboundAwaitsModel: false
        )

        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        store.set(cursor, for: transcript)
        store.setAggregate(aggregate, for: transcript)
        store.flush()

        let loaded = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        #expect(loaded.state(for: transcript) == cursor)
        #expect(loaded.aggregate(for: transcript, provider: .claude) == aggregate)
        #expect(loaded.aggregate(for: transcript, provider: .codex) == nil)
    }

    @Test("debounced save flushes without explicit flush")
    func debouncedFlushWorks() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/example/.codex/sessions/rollout-session.jsonl")
        let cursor = TailCursorState(inode: 7, size: 80, offset: 40)

        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 0.05)
        store.set(cursor, for: transcript)
        try await Task.sleep(nanoseconds: 250_000_000)

        let loaded = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        #expect(loaded.state(for: transcript) == cursor)
    }

    @Test("stored JSON uses path hashes instead of raw transcript paths")
    func pathHashingOmitsRawPath() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/synthetic-secret/.claude/projects/private/session.jsonl")
        let cursor = TailCursorState(inode: 9, size: 128, offset: 128)

        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        store.set(cursor, for: transcript)
        store.flush()

        let data = try Data(contentsOf: storageURL(in: dir))
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("/Users"))
        #expect(!json.contains("synthetic-secret"))
        #expect(!json.contains("session.jsonl"))
    }
}
