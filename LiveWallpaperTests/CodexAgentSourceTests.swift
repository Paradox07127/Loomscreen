import Foundation
import Testing
@testable import LiveWallpaper

@Suite("CodexAgentSource")
struct CodexAgentSourceTests {
    @Test("Scanner enumerates recent rollout files from Codex date trees")
    func scannerEnumeratesRecentRollouts() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 3_600)

        for index in 0..<45 {
            let url = root
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent("2026", isDirectory: true)
                .appendingPathComponent("07", isDirectory: true)
                .appendingPathComponent(index < 30 ? "05" : "04", isDirectory: true)
                .appendingPathComponent("rollout-\(String(format: "%02d", index)).jsonl")
            try Self.writeFile(url, contents: "{}\n", modificationDate: now.addingTimeInterval(Double(-index * 60)))
        }
        let oldURL = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("07", isDirectory: true)
            .appendingPathComponent("03", isDirectory: true)
            .appendingPathComponent("rollout-old.jsonl")
        try Self.writeFile(oldURL, contents: "{}\n", modificationDate: now.addingTimeInterval(-(49 * 60 * 60)))
        let ignoredURL = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("07", isDirectory: true)
            .appendingPathComponent("05", isDirectory: true)
            .appendingPathComponent("notes.txt")
        try Self.writeFile(ignoredURL, contents: "not jsonl", modificationDate: now)

        let scanner = CodexSessionScanner(rootURL: root, processProbe: { true })
        let files = try scanner.scan(now: now)

        #expect(files.count == 40)
        let names = files.map { $0.url.lastPathComponent }
        #expect(names.allSatisfy { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") })
        #expect(files.first?.url.lastPathComponent == "rollout-00.jsonl")
        #expect(files.last?.url.lastPathComponent == "rollout-39.jsonl")
        #expect(files.first?.processAlive == true)
        #expect(files.last?.processAlive == false)
        let scannedURLs = files.map { $0.url }
        #expect(!scannedURLs.contains(oldURL))
        #expect(!scannedURLs.contains(ignoredURL))
    }

    @Test("Ended sessions older than two hours are pruned from agent snapshots")
    func endedPruning() {
        let now = Date(timeIntervalSince1970: 20_000)
        let recentURL = URL(fileURLWithPath: "/tmp/recent.jsonl")
        let oldURL = URL(fileURLWithPath: "/tmp/old.jsonl")
        let liveURL = URL(fileURLWithPath: "/tmp/live.jsonl")
        let recentEnded = Self.model(id: "recent-ended", eventTime: now.addingTimeInterval(-3_000), eventType: "task_complete")
        let oldEnded = Self.model(id: "old-ended", eventTime: now.addingTimeInterval(-8_000), eventType: "task_complete")
        let live = Self.model(id: "live", eventTime: now.addingTimeInterval(-5), eventType: "task_started")

        let states = CodexAgentSource.sessionStates(
            modelsByURL: [
                recentURL: recentEnded,
                oldURL: oldEnded,
                liveURL: live
            ],
            files: [
                .init(url: recentURL, modificationDate: now.addingTimeInterval(-3_000), processAlive: false),
                .init(url: oldURL, modificationDate: now.addingTimeInterval(-8_000), processAlive: false),
                .init(url: liveURL, modificationDate: now.addingTimeInterval(-5), processAlive: true)
            ],
            now: now
        )

        #expect(states.map(\.id) == ["codex:live", "codex:recent-ended"])
        #expect(states.map(\.status) == [.running, .ended])
    }

    @Test("Usage sums today's Codex tokens and leaves cost nil")
    func usageSumsTodaysTokens() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let now = Date(timeIntervalSince1970: 86_400 + 3_600)
        let today = Self.model(
            id: "today",
            eventTime: Date(timeIntervalSince1970: 86_400 + 1_000),
            eventType: "task_complete",
            tokens: MonitorTokenTotals(input: 10, output: 5, cacheRead: 3, cacheWrite: 0)
        )
        let yesterday = Self.model(
            id: "yesterday",
            eventTime: Date(timeIntervalSince1970: 3_000),
            eventType: "task_complete",
            tokens: MonitorTokenTotals(input: 100, output: 50, cacheRead: 30, cacheWrite: 0)
        )

        let usage = CodexAgentSource.usageSnapshot(from: [today, yesterday], now: now, calendar: calendar)

        #expect(usage.costTodayUSD == nil)
        #expect(usage.tokensToday == MonitorTokenTotals(input: 10, output: 5, cacheRead: 3, cacheWrite: 0))
    }

    private static func model(
        id: String,
        eventTime: Date,
        eventType: String,
        tokens: MonitorTokenTotals = .zero
    ) -> CodexSessionModel {
        var model = CodexSessionModel()
        model.ingest(line(
            timestamp: isoString(eventTime),
            type: "session_meta",
            payload: #"{"id": "\#(id)", "cwd": "/tmp/\#(id)"}"#
        ))
        model.ingest(line(
            timestamp: isoString(eventTime),
            type: "event_msg",
            payload: #"{"type": "\#(eventType)"}"#
        ))
        if tokens != .zero {
            model.ingest(line(
                timestamp: isoString(eventTime),
                type: "event_msg",
                payload: """
                {
                  "type": "token_count",
                  "info": {
                    "total_token_usage": {
                      "input_tokens": \(tokens.input),
                      "cached_input_tokens": \(tokens.cacheRead),
                      "output_tokens": \(tokens.output)
                    }
                  }
                }
                """
            ))
        }
        return model
    }

    private static func line(timestamp: String, type: String, payload: String) -> Data {
        Data(#"{"timestamp":"\#(timestamp)","type":"\#(type)","payload":\#(payload)}"#.utf8)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("CodexAgentSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeFile(_ url: URL, contents: String, modificationDate: Date) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }
}
