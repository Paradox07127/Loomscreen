import Foundation
import Testing
@testable import LiveWallpaper

/// Usage-ledger aggregation: pricing, per-model + per-day rollup incl. day-window
/// bucketing, the whole-file Claude/Codex parsers, per-file memoization, and
/// burn-rate windowing. UTC calendar throughout so day keys are deterministic.
@Suite("Monitor usage aggregation")
struct MonitorUsageAggregationTests {
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    /// Epoch for a UTC calendar day at noon (well clear of a boundary).
    private func noon(_ day: String) -> Double {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)!
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)!.timeIntervalSince1970 + 12 * 3600
    }

    // MARK: - Pricing

    @Test("pricing keyed by prefix; unknown → nil, opus > sonnet")
    func pricing() {
        let mix = MonitorTokenTotals(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)
        let opus = MonitorTokenPricing.cost(model: "claude-opus-4-8", tokens: mix)
        let sonnet = MonitorTokenPricing.cost(model: "claude-sonnet-5", tokens: mix)
        #expect(opus == 15)
        #expect(sonnet == 3)
        #expect((opus ?? 0) > (sonnet ?? 0))
        #expect(MonitorTokenPricing.cost(model: "claude-fable-5", tokens: mix) == nil)
        #expect(MonitorTokenPricing.cost(model: "gpt-5.5", tokens: mix) == nil)
    }

    // MARK: - Rollup math + day bucketing

    @Test("compose rolls per-model + per-day totals over the window")
    func rollupMath() {
        let today = MonitorUsageRollup.dayKey(noon("2026-07-06"), calendar: Self.utc)
        let yesterday = MonitorUsageRollup.dayKey(noon("2026-07-05"), calendar: Self.utc)

        var f1 = MonitorFileUsageBuckets()
        f1.add(day: today, model: "claude-opus-4-8", tokens: MonitorTokenTotals(input: 100, output: 10, cacheRead: 0, cacheWrite: 0))
        f1.add(day: yesterday, model: "claude-opus-4-8", tokens: MonitorTokenTotals(input: 50, output: 5, cacheRead: 0, cacheWrite: 0))
        var f2 = MonitorFileUsageBuckets()
        f2.add(day: today, model: "claude-sonnet-5", tokens: MonitorTokenTotals(input: 200, output: 20, cacheRead: 0, cacheWrite: 0))

        let out = MonitorUsageRollup.compose(files: [f1, f2], now: noon("2026-07-06"), calendar: Self.utc)

        // perModel sorted by descending total tokens: sonnet(220) > opus(165).
        let models = out.perModel ?? []
        #expect(models.count == 2)
        #expect(models[0].model == "claude-sonnet-5")
        #expect(models[0].tokens == MonitorTokenTotals(input: 200, output: 20, cacheRead: 0, cacheWrite: 0))
        #expect(models[1].model == "claude-opus-4-8")
        #expect(models[1].tokens == MonitorTokenTotals(input: 150, output: 15, cacheRead: 0, cacheWrite: 0))
        #expect(models[1].costUSD != nil)

        // dailyActivity covers the 14-day window ending today, ascending, with the
        // two active days populated and the rest zero.
        let days = out.dailyActivity ?? []
        #expect(days.count == MonitorUsageRollup.dayWindow)
        #expect(days.last?.day == today)
        let todayBucket = days.first { $0.day == today }
        #expect(todayBucket?.tokens == MonitorTokenTotals(input: 300, output: 30, cacheRead: 0, cacheWrite: 0))
        let yesterdayBucket = days.first { $0.day == yesterday }
        #expect(yesterdayBucket?.tokens == MonitorTokenTotals(input: 50, output: 5, cacheRead: 0, cacheWrite: 0))
    }

    @Test("days outside the 14-day window are excluded from totals")
    func windowExclusion() {
        let inWindow = MonitorUsageRollup.dayKey(noon("2026-07-06"), calendar: Self.utc)
        let old = MonitorUsageRollup.dayKey(noon("2026-06-01"), calendar: Self.utc)  // > 14 days ago
        var f = MonitorFileUsageBuckets()
        f.add(day: inWindow, model: "claude-opus-4-8", tokens: MonitorTokenTotals(input: 100, output: 0, cacheRead: 0, cacheWrite: 0))
        f.add(day: old, model: "claude-opus-4-8", tokens: MonitorTokenTotals(input: 9_999, output: 0, cacheRead: 0, cacheWrite: 0))

        let out = MonitorUsageRollup.compose(files: [f], now: noon("2026-07-06"), calendar: Self.utc)
        // Only the in-window day contributes.
        #expect(out.perModel?.first?.tokens.input == 100)
        #expect((out.dailyActivity ?? []).allSatisfy { $0.day != old })
    }

    @Test("windowDays yields 14 ascending keys ending today")
    func windowDaysShape() {
        let keys = MonitorUsageRollup.windowDays(now: noon("2026-07-06"), calendar: Self.utc)
        #expect(keys.count == 14)
        #expect(keys.first == "2026-06-23")
        #expect(keys.last == "2026-07-06")
        #expect(keys == keys.sorted())
    }

    @Test("empty input composes to nil, not empty arrays")
    func emptyComposesNil() {
        let out = MonitorUsageRollup.compose(files: [], now: noon("2026-07-06"), calendar: Self.utc)
        #expect(out.perModel == nil)
        #expect(out.dailyActivity == nil)
    }

    // MARK: - Claude / Codex file parsers

    @Test("Claude parser buckets each assistant line by its own day + model")
    func claudeFileParse() {
        // Two assistant lines on different UTC days.
        let lines = [
            claudeAssistant(day: "2026-07-05", model: "claude-opus-4-8", input: 100, output: 10),
            claudeAssistant(day: "2026-07-06", model: "claude-opus-4-8", input: 200, output: 20),
            claudeAssistant(day: "2026-07-06", model: "claude-sonnet-5", input: 5, output: 1)
        ]
        let data = Data(lines.joined(separator: "\n").utf8)
        let buckets = MonitorUsageFileParser.parse(data: data, provider: .claude, calendar: Self.utc)

        #expect(buckets.byDayModel["2026-07-05"]?["claude-opus-4-8"]?.input == 100)
        #expect(buckets.byDayModel["2026-07-06"]?["claude-opus-4-8"]?.input == 200)
        #expect(buckets.byDayModel["2026-07-06"]?["claude-sonnet-5"]?.output == 1)
    }

    @Test("Claude parser ignores sidechain + non-assistant lines")
    func claudeParseIgnores() {
        let assistantLine = claudeAssistant(day: "2026-07-06", model: "claude-opus-4-8", input: 100, output: 10)
        let sidechain = #"{"type":"assistant","isSidechain":true,"timestamp":"2026-07-06T12:00:00.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":9999,"output_tokens":0}}}"#
        let user = #"{"type":"user","timestamp":"2026-07-06T12:00:00.000Z","message":{"content":"hi"}}"#
        let data = Data([assistantLine, sidechain, user].joined(separator: "\n").utf8)
        let buckets = MonitorUsageFileParser.parse(data: data, provider: .claude, calendar: Self.utc)
        #expect(buckets.byDayModel["2026-07-06"]?["claude-opus-4-8"]?.input == 100)  // sidechain 9999 excluded
    }

    @Test("Codex parser buckets the file's final cumulative total on its last day")
    func codexFileParse() {
        // token_count carries a running total; the last one is the file's total.
        let lines = [
            codexMeta(day: "2026-07-06", model: "gpt-5.5"),
            codexTokenCount(day: "2026-07-06", input: 100, cached: 10, output: 5),
            codexTokenCount(day: "2026-07-06", input: 300, cached: 40, output: 25)
        ]
        let data = Data(lines.joined(separator: "\n").utf8)
        let buckets = MonitorUsageFileParser.parse(data: data, provider: .codex, calendar: Self.utc)
        let tokens = buckets.byDayModel["2026-07-06"]?["gpt-5.5"]
        #expect(tokens?.input == 300)
        #expect(tokens?.cacheRead == 40)
        #expect(tokens?.output == 25)
    }

    // MARK: - Per-file memoization

    @Test("backfill memoizes unchanged files and re-reads changed ones")
    func backfillMemoization() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageBackfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("rollout-1.jsonl")
        let firstLine = claudeAssistant(day: "2026-07-06", model: "claude-opus-4-8", input: 100, output: 10)
        try Data((firstLine + "\n").utf8).write(to: fileURL)
        let mtime1 = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime1], ofItemAtPath: fileURL.path)
        let size1 = UInt64((try Data(contentsOf: fileURL)).count)

        let cache = MonitorUsageBackfillCache(refreshInterval: 0, calendar: Self.utc)
        let ref1 = MonitorUsageFileRef(url: fileURL, provider: .claude, size: size1, mtime: mtime1)
        let out1 = cache.refresh(files: [ref1], now: Date(timeIntervalSince1970: 2_000_000))
        #expect(out1.first?.byDayModel["2026-07-06"]?["claude-opus-4-8"]?.input == 100)

        // Same fingerprint → memoized: even though the file's bytes changed on disk,
        // the cache should NOT re-read while size/mtime are unchanged.
        try Data((claudeAssistant(day: "2026-07-06", model: "claude-opus-4-8", input: 777, output: 0) + "\n").utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: mtime1], ofItemAtPath: fileURL.path)
        let out2 = cache.refresh(files: [ref1], now: Date(timeIntervalSince1970: 3_000_000))
        #expect(out2.first?.byDayModel["2026-07-06"]?["claude-opus-4-8"]?.input == 100)  // still memoized value

        // Changed fingerprint (new size + mtime) → re-read.
        let size3 = UInt64((try Data(contentsOf: fileURL)).count)
        let mtime3 = Date(timeIntervalSince1970: 4_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime3], ofItemAtPath: fileURL.path)
        let ref3 = MonitorUsageFileRef(url: fileURL, provider: .claude, size: size3 &+ 1, mtime: mtime3)
        let out3 = cache.refresh(files: [ref3], now: Date(timeIntervalSince1970: 5_000_000))
        #expect(out3.first?.byDayModel["2026-07-06"]?["claude-opus-4-8"]?.input == 777)  // re-read
    }

    @Test("Streaming file parse matches the in-memory parse for a normal file (blank lines + no trailing newline)")
    func streamingParseMatchesInMemory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Include a blank line (consecutive newlines) and NO trailing newline, so
        // the streaming reader's edge cases are exercised against the in-memory path.
        let lines = [
            claudeAssistant(day: "2026-07-05", model: "claude-opus-4-8", input: 100, output: 10),
            "",  // blank line — must be skipped by both paths
            claudeAssistant(day: "2026-07-06", model: "claude-opus-4-8", input: 200, output: 20),
            claudeAssistant(day: "2026-07-06", model: "claude-sonnet-5", input: 5, output: 1),
        ]
        let text = lines.joined(separator: "\n")   // no trailing newline
        let data = Data(text.utf8)
        let fileURL = dir.appendingPathComponent("rollout-stream.jsonl")
        try data.write(to: fileURL)

        let streamed = MonitorUsageFileParser.parse(url: fileURL, provider: .claude, calendar: Self.utc)
        let inMemory = MonitorUsageFileParser.parse(data: data, provider: .claude, calendar: Self.utc)

        #expect(streamed.byDayModel == inMemory.byDayModel)
        #expect(streamed.byDayModel["2026-07-05"]?["claude-opus-4-8"]?.input == 100)
        #expect(streamed.byDayModel["2026-07-06"]?["claude-opus-4-8"]?.input == 200)
        #expect(streamed.byDayModel["2026-07-06"]?["claude-sonnet-5"]?.output == 1)
    }

    @Test("Streaming reader handles lines longer than one chunk")
    func streamingParseAcrossChunkBoundary() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStreamBig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A valid assistant line padded (via an ignored field) well past a 64 KiB
        // chunk, so the reader must stitch a single logical line across reads.
        let pad = String(repeating: "x", count: 200_000)
        let bigLine = #"{"type":"assistant","isSidechain":false,"timestamp":"2026-07-06T12:00:00.000Z","sessionId":"s","cwd":"/tmp/p","_pad":"\#(pad)","message":{"role":"assistant","model":"claude-opus-4-8","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}],"usage":{"input_tokens":321,"output_tokens":7,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
        let data = Data((bigLine + "\n").utf8)
        let fileURL = dir.appendingPathComponent("rollout-big.jsonl")
        try data.write(to: fileURL)

        let streamed = MonitorUsageFileParser.parse(url: fileURL, provider: .claude, calendar: Self.utc)
        #expect(streamed.byDayModel["2026-07-06"]?["claude-opus-4-8"]?.input == 321)
    }

    @Test("An oversized transcript is skipped (empty buckets), not read into memory")
    func oversizedFileSkipped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageOversized-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A perfectly valid file whose real size clears the (tiny, injected) cap.
        let line = claudeAssistant(day: "2026-07-06", model: "claude-opus-4-8", input: 100, output: 10)
        let fileURL = dir.appendingPathComponent("rollout-huge.jsonl")
        try Data((line + "\n").utf8).write(to: fileURL)
        let mtime = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: fileURL.path)
        let size = UInt64((try Data(contentsOf: fileURL)).count)

        // Cap below the file's real size → the file is skipped despite being valid.
        let cache = MonitorUsageBackfillCache(refreshInterval: 0, calendar: Self.utc, maxFileBytes: size - 1)
        let ref = MonitorUsageFileRef(url: fileURL, provider: .claude, size: size, mtime: mtime)
        let out = cache.refresh(files: [ref], now: Date(timeIntervalSince1970: 2_000_000))
        #expect(out.first?.byDayModel.isEmpty == true)

        // A cap comfortably above the file's size reads it normally.
        let cache2 = MonitorUsageBackfillCache(refreshInterval: 0, calendar: Self.utc, maxFileBytes: size + 1)
        let out2 = cache2.refresh(files: [ref], now: Date(timeIntervalSince1970: 2_000_000))
        #expect(out2.first?.byDayModel["2026-07-06"]?["claude-opus-4-8"]?.input == 100)
    }

    @Test("backfill refresh cadence gate")
    func backfillCadence() {
        let cache = MonitorUsageBackfillCache(refreshInterval: 300, calendar: Self.utc)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(cache.shouldRefresh(now: t0))       // never refreshed → yes
        cache.refresh(files: [], now: t0)
        #expect(!cache.shouldRefresh(now: t0.addingTimeInterval(299)))  // inside window → no
        #expect(cache.shouldRefresh(now: t0.addingTimeInterval(301)))   // past window → yes
    }

    // MARK: - Burn rate windowing

    @Test("burn rate nil until window spans minSpan, then delta-per-hour")
    func burnRate() {
        var window = MonitorBurnRateWindow(window: 60 * 60, minSpan: 120)
        window.record(at: 0, cumulativeTokens: 1_000, cumulativeCost: 1.0)
        // Not enough spread yet.
        #expect(window.rates().tokensPerHour == nil)

        // 1800s (0.5h) later, +3600 tokens → 7200 tokens/hour; +$2 → $4/hour.
        window.record(at: 1_800, cumulativeTokens: 4_600, cumulativeCost: 3.0)
        let rates = window.rates()
        #expect(rates.tokensPerHour == 7_200)
        #expect(rates.costPerHour == 4.0)
    }

    @Test("burn rate drops samples older than the window and resets on counter drop")
    func burnRateWindowingAndReset() {
        var window = MonitorBurnRateWindow(window: 600, minSpan: 60)  // 10-min window
        window.record(at: 0, cumulativeTokens: 100, cumulativeCost: nil)
        window.record(at: 1_000, cumulativeTokens: 200, cumulativeCost: nil)  // first sample pruned (age 1000 > 600)
        // Only the last sample remains → span 0 → nil.
        #expect(window.rates().tokensPerHour == nil)

        // Counter drop (day rollover) invalidates earlier higher samples.
        var w2 = MonitorBurnRateWindow(window: 3_600, minSpan: 60)
        w2.record(at: 0, cumulativeTokens: 5_000, cumulativeCost: nil)
        w2.record(at: 100, cumulativeTokens: 10, cumulativeCost: nil)   // reset — drops the 5000 sample
        w2.record(at: 200, cumulativeTokens: 1_810, cumulativeCost: nil)
        let rates = w2.rates()
        // From the reset baseline (10 @100) to (1810 @200): +1800 over 100s = 64_800/h.
        #expect(rates.tokensPerHour == 64_800)
    }

    // MARK: - Fixtures

    private func claudeAssistant(day: String, model: String, input: Int, output: Int) -> String {
        #"{"type":"assistant","isSidechain":false,"timestamp":"\#(day)T12:00:00.000Z","sessionId":"s","cwd":"/tmp/p","message":{"role":"assistant","model":"\#(model)","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
    }

    private func codexMeta(day: String, model: String) -> String {
        #"{"timestamp":"\#(day)T12:00:00.000Z","type":"session_meta","payload":{"id":"cx","cwd":"/tmp/p","model":"\#(model)"}}"#
    }

    private func codexTokenCount(day: String, input: Int, cached: Int, output: Int) -> String {
        #"{"timestamp":"\#(day)T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output)}}}}"#
    }
}
