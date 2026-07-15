import Testing
import Foundation
@testable import LiveWallpaper

@Suite("Claude rate-limit reader")
struct ClaudeRateLimitReaderTests {

    /// Writes `json` as the statusline payload into a fresh temp root and returns
    /// (root, payloadURL) so tests can also tweak the file's mtime.
    private func makeRoot(json: String) throws -> (root: URL, payload: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ratelimit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = root.appendingPathComponent(ClaudeRateLimitReader.payloadFileName)
        try json.data(using: .utf8)!.write(to: payload)
        return (root, payload)
    }

    @Test("Epoch resets_at parse to plain seconds")
    func epochResetsForm() throws {
        let json = """
        { "rate_limits": {
            "five_hour": { "used_percentage": 42.5, "resets_at": 1751000000 },
            "seven_day": { "used_percentage": 71, "resets_at": 1751500000 } } }
        """
        let (root, _) = try makeRoot(json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = try #require(ClaudeRateLimitReader(rootURL: root).currentLimits())

        #expect(limits.fiveHourUsedPercent == 42.5)
        #expect(limits.fiveHourResetsAt == 1751000000)
        #expect(limits.weekUsedPercent == 71)
        #expect(limits.weekResetsAt == 1751500000)
    }

    @Test("ISO8601 resets_at strings collapse to epoch seconds")
    func iso8601ResetsForm() throws {
        // 2026-01-01T00:00:00Z == 1767225600 epoch.
        let json = """
        { "rate_limits": {
            "five_hour": { "used_percentage": 10, "resets_at": "2026-01-01T00:00:00Z" },
            "seven_day": { "used_percentage": 20, "resets_at": "2026-01-01T00:00:00.500Z" } } }
        """
        let (root, _) = try makeRoot(json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = try #require(ClaudeRateLimitReader(rootURL: root).currentLimits())

        #expect(limits.fiveHourResetsAt == 1767225600)
        // Fractional form parses too (0.5s past the same instant).
        let week = try #require(limits.weekResetsAt)
        #expect(abs(week - 1767225600.5) < 0.01)
    }

    @Test("Numeric-string percentages and resets coerce")
    func numericStringForms() throws {
        let json = """
        { "rate_limits": {
            "five_hour": { "used_percentage": "55.5", "resets_at": "1751000000" } } }
        """
        let (root, _) = try makeRoot(json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = try #require(ClaudeRateLimitReader(rootURL: root).currentLimits())

        #expect(limits.fiveHourUsedPercent == 55.5)
        #expect(limits.fiveHourResetsAt == 1751000000)
    }

    @Test("Missing seven_day section leaves weekly fields nil")
    func missingWeeklySection() throws {
        let json = """
        { "rate_limits": { "five_hour": { "used_percentage": 33 } } }
        """
        let (root, _) = try makeRoot(json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = try #require(ClaudeRateLimitReader(rootURL: root).currentLimits())

        #expect(limits.fiveHourUsedPercent == 33)
        #expect(limits.fiveHourResetsAt == nil)
        #expect(limits.weekUsedPercent == nil)
        #expect(limits.weekResetsAt == nil)
    }

    @Test("Payload with no rate_limits section returns nil")
    func noRateLimitsSection() throws {
        let (root, _) = try makeRoot(json: #"{ "model": { "display_name": "Opus" } }"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ClaudeRateLimitReader(rootURL: root).currentLimits() == nil)
    }

    @Test("Malformed JSON returns nil, never throws")
    func malformedJSON() throws {
        let (root, _) = try makeRoot(json: "{ this is not json ")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ClaudeRateLimitReader(rootURL: root).currentLimits() == nil)
    }

    @Test("Absent file returns nil")
    func absentFile() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ratelimit-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(ClaudeRateLimitReader(rootURL: root).currentLimits() == nil)
    }

    @Test("Fresh payload timestamp is not stale")
    func freshTimestampNotStale() throws {
        let now = Date().timeIntervalSince1970
        let json = """
        { "timestamp": \(now),
          "rate_limits": { "five_hour": { "used_percentage": 5 } } }
        """
        let (root, _) = try makeRoot(json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = try #require(ClaudeRateLimitReader(rootURL: root).currentLimits())
        #expect(limits.isStale == false)
    }

    @Test("Old payload timestamp trips the stale flag but keeps values")
    func stalePayloadTimestamp() throws {
        let old = Date().timeIntervalSince1970 - (45 * 60)
        let json = """
        { "timestamp": \(old),
          "rate_limits": { "five_hour": { "used_percentage": 5 } } }
        """
        let (root, _) = try makeRoot(json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = try #require(ClaudeRateLimitReader(rootURL: root).currentLimits())
        #expect(limits.isStale == true)
        #expect(limits.fiveHourUsedPercent == 5)
    }

    @Test("Old file mtime trips stale when payload omits timestamp")
    func staleFromFileMTime() throws {
        // No timestamp field ⇒ falls back to mtime, which we backdate.
        let json = #"{ "rate_limits": { "five_hour": { "used_percentage": 5 } } }"#
        let (root, payload) = try makeRoot(json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-40 * 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: payload.path)

        let limits = try #require(ClaudeRateLimitReader(rootURL: root).currentLimits())
        #expect(limits.isStale == true)
    }
}
