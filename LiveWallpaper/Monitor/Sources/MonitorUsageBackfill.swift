import CryptoKit
import Foundation
import os

/// Reads whole transcript files into privacy-safe per-day/per-model token buckets
/// for the usage ledger's `perModel` + `dailyActivity`. Reads ONLY model id,
/// token usage, and timestamp — never prompt/argument/output content.
///
/// This is the bounded backfill half of the usage pipeline: it scans files whose
/// mtime falls inside the day window, memoizes each file's buckets against a
/// (path, size, mtime) fingerprint so an unchanged file is never re-read, and
/// refreshes no more often than `refreshInterval`. The live tail continues to
/// drive today's numbers; this fills the trailing history behind them.
final class MonitorUsageBackfillCache {
    private struct Entry { var fingerprint: MonitorUsageFileFingerprint; var buckets: MonitorFileUsageBuckets }

    private var entries: [String: Entry] = [:]       // keyed by path hash
    private var lastRefresh: Date = .distantPast
    private let refreshInterval: TimeInterval
    private let calendar: Calendar
    /// Files at or above this size are skipped outright — an honest empty bucket
    /// beats an I/O + memory spike in a wallpaper process. Transcripts this large
    /// are pathological; the live tail still drives today's numbers regardless.
    private let maxFileBytes: UInt64
    /// One-shot flag so the skip is logged once per cache lifetime, not per rescan.
    private var loggedOversized = false

    private static let log = os.Logger(subsystem: "com.livewallpaper", category: "MonitorUsageBackfill")

    /// Default oversized threshold (24 MB).
    static let defaultMaxFileBytes: UInt64 = 24 * 1024 * 1024

    init(
        refreshInterval: TimeInterval = 5 * 60,
        calendar: Calendar = .current,
        maxFileBytes: UInt64 = MonitorUsageBackfillCache.defaultMaxFileBytes
    ) {
        self.refreshInterval = refreshInterval
        self.calendar = calendar
        self.maxFileBytes = maxFileBytes
    }

    /// True when enough time has elapsed to justify another bounded rescan.
    func shouldRefresh(now: Date) -> Bool {
        now.timeIntervalSince(lastRefresh) >= refreshInterval
    }

    /// Rebuild buckets for the given files (already filtered to the mtime window by
    /// the caller). Unchanged files reuse memoized buckets; vanished files drop
    /// out. Returns every retained file's buckets for rollup. Marks the refresh
    /// time so `shouldRefresh` gates the next pass.
    @discardableResult
    func refresh(files: [MonitorUsageFileRef], now: Date) -> [MonitorFileUsageBuckets] {
        lastRefresh = now
        var next: [String: Entry] = [:]
        var result: [MonitorFileUsageBuckets] = []
        for file in files {
            let key = Self.pathKey(file.url)
            let fingerprint = MonitorUsageFileFingerprint(
                pathHash: key.hashValue,
                size: file.size,
                mtime: file.mtime.timeIntervalSince1970
            )
            if let existing = entries[key], existing.fingerprint == fingerprint {
                next[key] = existing
                result.append(existing.buckets)
                continue
            }
            // Skip pathologically large transcripts: reading tens of MB into memory
            // in a wallpaper process is exactly the spike we must avoid. Memoize an
            // empty bucket under the size-bearing fingerprint so it isn't re-checked
            // every rescan (a shrink below the cap changes the fingerprint → re-read).
            if file.size >= maxFileBytes {
                if !loggedOversized {
                    loggedOversized = true
                    Self.log.notice("Skipping oversized usage transcript (\(file.size, privacy: .public) bytes ≥ cap); leaving it out of the ledger backfill.")
                }
                let entry = Entry(fingerprint: fingerprint, buckets: MonitorFileUsageBuckets())
                next[key] = entry
                result.append(entry.buckets)
                continue
            }
            let buckets = MonitorUsageFileParser.parse(url: file.url, provider: file.provider, calendar: calendar)
            let entry = Entry(fingerprint: fingerprint, buckets: buckets)
            next[key] = entry
            result.append(buckets)
        }
        entries = next
        return result
    }

    /// Buckets from the last refresh (no re-read), for composing between refreshes.
    func cachedBuckets() -> [MonitorFileUsageBuckets] {
        entries.values.map(\.buckets)
    }

    private static func pathKey(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// One transcript file the backfill should account for.
struct MonitorUsageFileRef: Sendable, Equatable {
    var url: URL
    var provider: MonitorAgentProvider
    var size: UInt64
    var mtime: Date
}

/// Whole-file transcript parser producing `MonitorFileUsageBuckets`. Separate
/// from the live tail models because the ledger wants historic totals, not live
/// status; it deliberately shares neither state nor mutation with them.
enum MonitorUsageFileParser {
    /// Stream a transcript from disk line-by-line so peak memory is bounded by the
    /// chunk size, not the file size. A file that vanishes / can't be opened yields
    /// empty buckets (same as before). Parse results are identical to the in-memory
    /// `parse(data:)` path for well-formed files — both fold the same line sequence.
    static func parse(url: URL, provider: MonitorAgentProvider, calendar: Calendar = .current) -> MonitorFileUsageBuckets {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return MonitorFileUsageBuckets() }
        defer { try? handle.close() }
        let lines = StreamingLineReader(handle: handle)
        switch provider {
        case .claude: return parseClaude(lines: AnySequence(lines), calendar: calendar)
        case .codex: return parseCodex(lines: AnySequence(lines), calendar: calendar)
        }
    }

    static func parse(data: Data, provider: MonitorAgentProvider, calendar: Calendar = .current) -> MonitorFileUsageBuckets {
        let lines = AnySequence(splitLines(data))
        switch provider {
        case .claude: return parseClaude(lines: lines, calendar: calendar)
        case .codex: return parseCodex(lines: lines, calendar: calendar)
        }
    }

    /// Claude: each assistant line carries its own `message.usage`; bucket per line
    /// by that line's local day + model. This is exact per-day attribution.
    static func parseClaude(lines: AnySequence<Data>, calendar: Calendar) -> MonitorFileUsageBuckets {
        var buckets = MonitorFileUsageBuckets()
        for lineData in lines {
            guard let line = ClaudeTranscriptLine(data: lineData) else { continue }
            guard line.type == .assistant, !line.isSidechain,
                  let usage = line.usage, let ts = line.timestamp,
                  let model = line.model else { continue }
            let tokens = MonitorTokenTotals(
                input: usage.input, output: usage.output,
                cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite
            )
            let day = MonitorUsageRollup.dayKey(ts.timeIntervalSince1970, calendar: calendar)
            buckets.add(day: day, model: model, tokens: tokens)
        }
        return buckets
    }

    /// Codex: `token_count` reports a running `total_token_usage`, so per-line
    /// deltas aren't available. Attribute the file's final total to its last-event
    /// day + model — a best-effort day bucket (documented imprecision at the day
    /// boundary for multi-day Codex sessions; the common case is a same-day run).
    static func parseCodex(lines: AnySequence<Data>, calendar: Calendar) -> MonitorFileUsageBuckets {
        var buckets = MonitorFileUsageBuckets()
        var model: String?
        var latestTotal: MonitorTokenTotals = .zero
        var latestTotalAt: Date?
        var accumulated: MonitorTokenTotals = .zero
        var sawCumulative = false

        for lineData in lines {
            guard let object = try? JSONSerialization.jsonObject(with: lineData),
                  let obj = object as? [String: Any] else { continue }
            let payload = obj["payload"] as? [String: Any] ?? [:]
            if let m = codexModel(in: payload) { model = m }
            let ts = codexTimestamp(line: obj, payload: payload)

            guard stringValue(obj["type"]) == "event_msg",
                  stringValue(payload["type"]) == "token_count" else { continue }

            let info = payload["info"] as? [String: Any]
            if let total = (info?["total_token_usage"] ?? payload["total_token_usage"]) as? [String: Any] {
                latestTotal = codexTotals(total)
                latestTotalAt = ts ?? latestTotalAt
                sawCumulative = true
            } else if let last = (info?["last_token_usage"] ?? payload["last_token_usage"]) as? [String: Any] {
                accumulated = accumulated + codexTotals(last)
                latestTotalAt = ts ?? latestTotalAt
            }
        }

        let finalTotal = sawCumulative ? latestTotal : accumulated
        if finalTotal != .zero, let at = latestTotalAt {
            let day = MonitorUsageRollup.dayKey(at.timeIntervalSince1970, calendar: calendar)
            buckets.add(day: day, model: model ?? "codex", tokens: finalTotal)
        }
        return buckets
    }

    // MARK: - Streaming line reader

    /// Reads a `FileHandle` in bounded chunks and yields one `Data` per newline-
    /// delimited line, so peak memory is O(chunk + longest line) regardless of file
    /// size. Semantics match `splitLines`: `\n` splits, empty lines (consecutive
    /// newlines) are skipped, and a final non-empty segment with no trailing newline
    /// is emitted. Not thread-safe; a fresh reader is created per parse.
    struct StreamingLineReader: Sequence {
        let handle: FileHandle
        var chunkSize: Int = 1 << 16   // 64 KiB

        func makeIterator() -> Iterator {
            Iterator(handle: handle, chunkSize: chunkSize)
        }

        struct Iterator: IteratorProtocol {
            private let handle: FileHandle
            private let chunkSize: Int
            private var buffer = Data()
            private var atEOF = false
            private let newline: UInt8 = 0x0A

            init(handle: FileHandle, chunkSize: Int) {
                self.handle = handle
                self.chunkSize = Swift.max(chunkSize, 1)
            }

            mutating func next() -> Data? {
                while true {
                    // Emit any complete line already buffered, skipping empty ones.
                    // Re-base indices off `startIndex` so this is correct even if the
                    // buffer became a slice after a prior removal.
                    while let nl = buffer.firstIndex(of: newline) {
                        let line = Data(buffer[buffer.startIndex..<nl])
                        buffer = Data(buffer[buffer.index(after: nl)...])
                        if !line.isEmpty { return line }
                    }
                    if atEOF {
                        // Flush a trailing non-empty segment (no closing newline).
                        guard !buffer.isEmpty else { return nil }
                        let tail = Data(buffer)
                        buffer = Data()
                        return tail
                    }
                    let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
                    if let chunk, !chunk.isEmpty {
                        buffer.append(chunk)
                    } else {
                        atEOF = true
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static func splitLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        let newline: UInt8 = 0x0A
        while let nl = data[start...].firstIndex(of: newline) {
            if nl > start { lines.append(data.subdata(in: start..<nl)) }
            start = data.index(after: nl)
        }
        if start < data.endIndex { lines.append(data.subdata(in: start..<data.endIndex)) }
        return lines
    }

    private static func codexModel(in payload: [String: Any]) -> String? {
        if let model = stringValue(payload["model"]) { return model }
        if let collaboration = payload["collaboration_mode"] as? [String: Any],
           let settings = collaboration["settings"] as? [String: Any],
           let model = stringValue(settings["model"]) { return model }
        if let info = payload["info"] as? [String: Any],
           let model = stringValue(info["model"]) { return model }
        return nil
    }

    private static func codexTimestamp(line: [String: Any], payload: [String: Any]) -> Date? {
        guard let value = stringValue(line["timestamp"]) ?? stringValue(payload["timestamp"]) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func codexTotals(_ usage: [String: Any]) -> MonitorTokenTotals {
        MonitorTokenTotals(
            input: intValue(usage["input_tokens"]) ?? intValue(usage["input"]) ?? 0,
            output: intValue(usage["output_tokens"]) ?? intValue(usage["output"]) ?? 0,
            cacheRead: intValue(usage["cached_input_tokens"])
                ?? intValue(usage["cache_read_tokens"]) ?? intValue(usage["cacheRead"]) ?? 0,
            cacheWrite: intValue(usage["cache_write_tokens"])
                ?? intValue(usage["cache_creation_input_tokens"]) ?? intValue(usage["cacheWrite"]) ?? 0
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let string = stringValue(value) { return Int(string) }
        return nil
    }
}
