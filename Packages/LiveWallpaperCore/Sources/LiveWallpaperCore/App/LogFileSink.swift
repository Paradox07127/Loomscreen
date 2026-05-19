import Foundation

/// Mirrors `Logger` output above a configurable threshold into a rotated text
/// file at `~/Library/Logs/LiveWallpaper/runtime.log`. The goal is so that a
/// maintainer can `tail -f` (or scroll back through) the most recent
/// app-level warnings and errors without having to set up a `log stream`
/// filter in Console.app ahead of time.
///
/// info/debug stay on `os_log` only — the file is intentionally scoped to
/// warning+ so it stays small and signal-dense.
public final class LogFileSink: @unchecked Sendable {
    public static let shared = LogFileSink()

    /// Public for the startup banner so users can easily find the log path.
    /// `nil` only if the Logs directory could not be created. Under the
    /// app sandbox this resolves to the container — see `tailCommandHint`
    /// for a copy-pastable `tail -f` line.
    public private(set) var fileURL: URL?

    /// One-liner shell command users can paste to follow the log. Includes
    /// the resolved container path so sandbox redirection isn't a surprise.
    /// `nil` when no log file is available.
    public var tailCommandHint: String? {
        guard let url = fileURL else { return nil }
        let quoted = url.path.contains(" ") ? "\"\(url.path)\"" : url.path
        return "tail -f \(quoted)"
    }

    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter
    private let rotationByteThreshold: UInt64 = 1_048_576  // 1 MiB
    private let rotationKeepCount = 3

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fileURL = Self.prepareLogFileURL()
    }

    /// Threshold below which messages are skipped (only the file mirror; the underlying `os.Logger` always receives the call).
    private func shouldRecord(_ level: Logger.Level) -> Bool {
        switch level {
        case .warning, .error, .fault, .notice:
            return true
        case .info, .debug:
            return false
        }
    }

    public func record(
        category: Logger.Category,
        level: Logger.Level,
        message: String,
        file: String,
        line: Int
    ) {
        guard shouldRecord(level) else { return }
        guard let url = fileURL else { return }

        let timestamp = formatter.string(from: Date())
        let levelTag = Self.levelTag(level)
        let fileName = (file as NSString).lastPathComponent
        let entry = "\(timestamp) [\(category.rawValue)] [\(levelTag)] \(fileName):\(line) — \(message)\n"

        lock.lock()
        defer { lock.unlock() }
        appendUnlocked(entry, to: url)
        rotateIfNeededUnlocked(url: url)
    }

    private func appendUnlocked(_ entry: String, to url: URL) {
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func rotateIfNeededUnlocked(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size >= rotationByteThreshold else {
            return
        }

        let fm = FileManager.default
        let oldest = url.deletingPathExtension()
            .appendingPathExtension("\(rotationKeepCount).log")
        try? fm.removeItem(at: oldest)
        for index in stride(from: rotationKeepCount - 1, through: 1, by: -1) {
            let src = url.deletingPathExtension().appendingPathExtension("\(index).log")
            let dst = url.deletingPathExtension().appendingPathExtension("\(index + 1).log")
            try? fm.moveItem(at: src, to: dst)
        }
        let firstRotated = url.deletingPathExtension().appendingPathExtension("1.log")
        try? fm.moveItem(at: url, to: firstRotated)
        try? Data().write(to: url, options: .atomic)
    }

    private static func levelTag(_ level: Logger.Level) -> String {
        switch level {
        case .debug:    return "DEBUG"
        case .info:     return "INFO"
        case .notice:   return "NOTICE"
        case .warning:  return "WARNING"
        case .error:    return "ERROR"
        case .fault:    return "FAULT"
        }
    }

    /// Tail recent WARNING/ERROR/FAULT lines for the bug-report sheet, taking
    /// the write lock so we never observe a partially-flushed entry from a
    /// concurrent `record(...)` and never race with rotation. Reads at most
    /// `maxReadBytes` from the file tail and returns up to `maxLines` lines.
    /// Each returned line is truncated to `maxLineLength` so a single
    /// pathological stack-trace can't blow past GitHub's issue-URL body
    /// ceiling when concatenated downstream.
    public func recentDiagnosticLines(
        maxLines: Int = 5,
        maxReadBytes: UInt64 = 256 * 1024,
        maxLineLength: Int = 500
    ) -> [String] {
        guard let url = fileURL else { return [] }
        lock.lock()
        defer { lock.unlock() }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let total = (try? handle.seekToEnd()) ?? 0
        let startOffset = total > maxReadBytes ? total - maxReadBytes : 0
        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return []
        }
        let data = (try? handle.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let matching = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { line in
                line.contains("[WARNING]") || line.contains("[ERROR]") || line.contains("[FAULT]")
            }
            .map { line in
                line.count > maxLineLength
                    ? String(line.prefix(maxLineLength)) + "…"
                    : line
            }
        return Array(matching.suffix(maxLines))
    }

    private static func prepareLogFileURL() -> URL? {
        let fm = FileManager.default
        guard let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = libraryURL.appendingPathComponent("Logs/LiveWallpaper", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let url = directory.appendingPathComponent("runtime.log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return url
    }
}
