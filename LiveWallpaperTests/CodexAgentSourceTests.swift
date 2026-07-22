import Foundation
@testable import LiveWallpaper
import os
import Testing

@Suite("CodexAgentSource")
struct CodexAgentSourceTests {
    @Test("Scanner enumerates recent rollout files from Codex date trees")
    func scannerEnumeratesRecentRollouts() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(
            Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 5, hour: 12))
        )
        let today = Self.shardDirectory(root: root, date: now)
        let yesterday = Self.shardDirectory(
            root: root,
            date: try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        )

        for index in 0..<45 {
            let url = (index < 30 ? today : yesterday)
                .appendingPathComponent("rollout-\(String(format: "%02d", index)).jsonl")
            try Self.writeFile(url, contents: "{}\n", modificationDate: now.addingTimeInterval(Double(-index * 60)))
        }
        let oldURL = Self.shardDirectory(
            root: root,
            date: try #require(Calendar.current.date(byAdding: .day, value: -3, to: now))
        )
            .appendingPathComponent("rollout-old.jsonl")
        try Self.writeFile(oldURL, contents: "{}\n", modificationDate: now.addingTimeInterval(-(49 * 60 * 60)))
        let ignoredURL = today
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

    @Test("Scanner prunes ten years of date shards while matching the legacy 48-hour oracle")
    func scannerPrunesHistoricalDateTree() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(
            Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 14))
        )
        let calendar = Calendar.current

        for year in 2016...2025 {
            for month in 1...12 {
                for day in 1...28 {
                    let date = try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
                    try FileManager.default.createDirectory(
                        at: Self.shardDirectory(root: root, date: date),
                        withIntermediateDirectories: true
                    )
                }
            }
        }

        for index in 0..<45 {
            let date = try #require(calendar.date(byAdding: .hour, value: -(index / 18) * 24, to: now))
            let url = Self.shardDirectory(root: root, date: date)
                .appendingPathComponent("rollout-recent-\(String(format: "%02d", index)).jsonl")
            try Self.writeFile(
                url,
                contents: "{}\n",
                modificationDate: now.addingTimeInterval(Double(-index * 60))
            )
        }
        let oldDate = try #require(calendar.date(byAdding: .year, value: -10, to: now))
        try Self.writeFile(
            Self.shardDirectory(root: root, date: oldDate).appendingPathComponent("rollout-old.jsonl"),
            contents: "{}\n",
            modificationDate: oldDate
        )

        let visits = OSAllocatedUnfairLock(initialState: [URL]())
        let scanner = CodexSessionScanner(
            rootURL: root,
            processProbe: { true },
            visitObserver: { url in visits.withLock { $0.append(url) } }
        )
        let optimized = try scanner.scan(now: now)
        let legacy = try Self.legacyFullTreeScan(root: root, now: now, processAlive: true)

        #expect(optimized == legacy)
        #expect(optimized.count == 40)

        let sessionsDepth = root
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL.pathComponents.count
        let visitedDayDirectories = Set(visits.withLock { $0 }.filter { url in
            let standardized = url.standardizedFileURL
            return standardized.pathComponents.count - sessionsDepth == 3
                && standardized.pathExtension.isEmpty
        })
        #expect(visitedDayDirectories.count <= 3)
        #expect(visitedDayDirectories.allSatisfy { url in
            !url.path(percentEncoded: false).contains("/2016/")
                && !url.path(percentEncoded: false).contains("/2025/")
        })
    }

    @Test("Scanner bounds descendants and round-robins discovered legacy roots")
    func scannerBoundsUnexpectedLayouts() throws {
        let root = try Self.makeTempDirectory()
        let outside = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.appendingPathComponent("sessions/04-locked").path
            )
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let now = Date()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        for index in 0..<300 {
            try Self.writeFile(
                sessions
                    .appendingPathComponent("00-overflow", isDirectory: true)
                    .appendingPathComponent(String(format: "entry-%03d.txt", index)),
                contents: "ignored",
                modificationDate: now
            )
        }
        let legacyURLs = ["01-legacy-a", "02-legacy-b"].map { directory in
            sessions
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("rollout-live.jsonl")
        }
        for url in legacyURLs {
            try Self.writeFile(url, contents: "{}\n", modificationDate: now)
        }

        let escapedURL = outside.appendingPathComponent("rollout-escaped.jsonl")
        try Self.writeFile(escapedURL, contents: "{}\n", modificationDate: now)
        try FileManager.default.createSymbolicLink(
            at: sessions.appendingPathComponent("03-escape", isDirectory: true),
            withDestinationURL: outside
        )

        let locked = sessions.appendingPathComponent("04-locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let visits = OSAllocatedUnfairLock(initialState: [URL]())
        let files = try CodexSessionScanner(
            rootURL: root,
            processProbe: { true },
            visitObserver: { url in visits.withLock { $0.append(url) } }
        ).scan(now: now)

        let resultURLs = Set(files.map(\.url))
        #expect(legacyURLs.allSatisfy { resultURLs.contains($0.standardizedFileURL) })
        #expect(!files.map(\.url).contains(escapedURL.standardizedFileURL))

        let sessionsDepth = sessions.standardizedFileURL.pathComponents.count
        let observed = visits.withLock { $0 }
        let topLevelVisits = observed.filter {
            $0.standardizedFileURL.pathComponents.count - sessionsDepth == 1
        }
        #expect(topLevelVisits.count <= 96)
        #expect(observed.count <= 96 + 256)
    }

    @Test("Scanner rejects a sessions symlink before legacy traversal")
    func scannerRejectsSessionsSymlink() throws {
        let root = try Self.makeTempDirectory()
        let outside = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let escapedURL = outside.appendingPathComponent("rollout-escaped.jsonl")
        try Self.writeFile(escapedURL, contents: "{}\n", modificationDate: Date())
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withDestinationURL: outside
        )

        let scanner = CodexSessionScanner(rootURL: root, processProbe: { true })
        #expect(throws: CodexSessionScanner.ScanError.unauthorized) {
            try scanner.scan()
        }
    }

    @Test("Scanner pulls a bounded top-level sample from ten thousand entries")
    func scannerBoundsHugeTopLevelFallback() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let filler = Data("ignored".utf8)
        for index in 0 ..< 10000 {
            try filler.write(
                to: sessions.appendingPathComponent(String(format: "filler-%05d.txt", index))
            )
        }

        let visits = OSAllocatedUnfairLock(initialState: [URL]())
        let files = try CodexSessionScanner(
            rootURL: root,
            processProbe: { false },
            visitObserver: { url in visits.withLock { $0.append(url) } }
        ).scan(now: Date())

        let observed = visits.withLock { $0 }
        let sessionsDepth = sessions.standardizedFileURL.pathComponents.count
        #expect(files.isEmpty)
        #expect(observed.count == 96)
        #expect(observed.allSatisfy {
            $0.standardizedFileURL.pathComponents.count - sessionsDepth == 1
        })
    }

    @Test("Scanner merges newer legacy sessions with date-sharded sessions")
    func scannerMergesMixedLayouts() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(
            Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 14))
        )
        let shardedURL = Self.shardDirectory(root: root, date: now)
            .appendingPathComponent("rollout-sharded.jsonl")
        let legacyURL = root
            .appendingPathComponent("sessions/00-legacy", isDirectory: true)
            .appendingPathComponent("rollout-newer.jsonl")
        try Self.writeFile(
            shardedURL,
            contents: "{}\n",
            modificationDate: now.addingTimeInterval(-300)
        )
        try Self.writeFile(
            legacyURL,
            contents: "{}\n",
            modificationDate: now.addingTimeInterval(-60)
        )

        let files = try CodexSessionScanner(
            rootURL: root,
            processProbe: { true }
        ).scan(now: now)

        #expect(files.map(\.url) == [
            legacyURL.standardizedFileURL,
            shardedURL.standardizedFileURL,
        ])
        #expect(files.allSatisfy { $0.processAlive })
    }

    @Test("Ledger file refs prune date-shards outside the 14-day window")
    func ledgerFileRefsPruneOldShards() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let calendar = Calendar.current
        let now = Date()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)

        func shardURL(daysAgo: Int, name: String) throws -> URL {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            let url = sessions
                .appendingPathComponent(String(format: "%04d", comps.year!), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.month!), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.day!), isDirectory: true)
                .appendingPathComponent(name)
            try Self.writeFile(url, contents: "{}\n", modificationDate: date)
            return url
        }

        let todayURL = try shardURL(daysAgo: 0, name: "rollout-today.jsonl")
        let inWindowURL = try shardURL(daysAgo: 10, name: "rollout-recent.jsonl")
        let oldURL = try shardURL(daysAgo: 40, name: "rollout-old.jsonl")
        _ = try shardURL(daysAgo: 1, name: "notes.txt")

        let refs = CodexAgentSource.ledgerFileRefs(rootURL: root, now: now)
        let urls = Set(refs.map(\.url.lastPathComponent))

        #expect(urls.contains(todayURL.lastPathComponent))
        #expect(urls.contains(inWindowURL.lastPathComponent))
        #expect(!urls.contains(oldURL.lastPathComponent))
        #expect(!urls.contains("notes.txt"))
        #expect(refs.allSatisfy { $0.provider == .codex })
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

    private static func shardDirectory(root: URL, date: Date, calendar: Calendar = .current) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", components.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day ?? 0), isDirectory: true)
    }

    private static func legacyFullTreeScan(
        root: URL,
        now: Date,
        processAlive: Bool
    ) throws -> [CodexSessionScanner.SessionFile] {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let enumerator = try #require(FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ))
        let cutoff = now.addingTimeInterval(-(48 * 60 * 60))
        var candidates: [(url: URL, modificationDate: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate >= cutoff else {
                continue
            }
            candidates.append((url.standardizedFileURL, modificationDate))
        }
        return candidates
            .sorted { lhs, rhs in
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate > rhs.modificationDate
                }
                return lhs.url.path(percentEncoded: false) < rhs.url.path(percentEncoded: false)
            }
            .prefix(40)
            .map { candidate in
                CodexSessionScanner.SessionFile(
                    url: candidate.url,
                    modificationDate: candidate.modificationDate,
                    processAlive: processAlive
                        && candidate.modificationDate >= now.addingTimeInterval(-(10 * 60))
                )
            }
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
