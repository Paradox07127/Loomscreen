import Foundation

/// Mirrors `Logger` output above a threshold into a rotated text file at
/// `~/Library/Logs/LiveWallpaper/runtime.log`, so a maintainer can `tail -f`
/// recent warnings/errors without setting up a Console.app `log stream` filter.
/// info/debug stay on `os_log` only — scoped to warning+ to stay small and signal-dense.
public final class LogFileSink: @unchecked Sendable {
    public static let shared = LogFileSink()

    /// `nil` only if the Logs directory could not be created. Under the
    /// app sandbox this resolves to the container — see `tailCommandHint`.
    public private(set) var fileURL: URL?

    /// Pasteable `tail -f` line with the resolved container path so sandbox
    /// redirection isn't a surprise. `nil` when no log file is available.
    public var tailCommandHint: String? {
        guard let url = fileURL else { return nil }
        let quoted = url.path.contains(" ") ? "\"\(url.path)\"" : url.path
        return "tail -f \(quoted)"
    }

    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter
    private let rotationByteThreshold: UInt64 = 1_048_576  // 1 MiB
    private static let rotationKeepCount = 3

    /// Persistent append handle + in-memory size, both guarded by `lock`. Avoids a
    /// per-line open/close + `stat` on the hot warning path. Reset on rotation.
    private var writeHandle: FileHandle?
    private var cachedSize: UInt64 = 0

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fileURL = Self.prepareLogFileURL()
        if let url = fileURL,
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 {
            cachedSize = size
        }
    }

    deinit {
        try? writeHandle?.close()
    }

    /// Gates only the file mirror; the underlying `os.Logger` always receives the call.
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
        guard let handle = openWriteHandleUnlocked(url) else {
            try? data.write(to: url, options: .atomic)
            cachedSize = UInt64(data.count)
            return
        }
        do {
            try handle.write(contentsOf: data)
            cachedSize &+= UInt64(data.count)
        } catch {
            try? handle.close()
            writeHandle = nil
        }
    }

    private func openWriteHandleUnlocked(_ url: URL) -> FileHandle? {
        if let handle = writeHandle { return handle }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        writeHandle = handle
        return handle
    }

    private func rotateIfNeededUnlocked(url: URL) {
        guard cachedSize >= rotationByteThreshold else { return }

        // Release the handle before moving the file out from under it; the next
        // append reopens against the fresh empty file.
        try? writeHandle?.close()
        writeHandle = nil

        let fm = FileManager.default
        let oldest = url.deletingPathExtension()
            .appendingPathExtension("\(Self.rotationKeepCount).log")
        try? fm.removeItem(at: oldest)
        for index in stride(from: Self.rotationKeepCount - 1, through: 1, by: -1) {
            let src = url.deletingPathExtension().appendingPathExtension("\(index).log")
            let dst = url.deletingPathExtension().appendingPathExtension("\(index + 1).log")
            try? fm.moveItem(at: src, to: dst)
        }
        let firstRotated = url.deletingPathExtension().appendingPathExtension("1.log")
        try? fm.moveItem(at: url, to: firstRotated)
        // moveItem keeps the source's mode — re-tighten in case the current
        // log predates the 0600 policy.
        try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: firstRotated.path)
        try? Data().write(to: url, options: .atomic)
        // `.atomic` writes via a temp file + rename, landing on default umask
        // permissions — reapply 0600 so a rotated file isn't laxer than the
        // one `prepareLogFileURL` created.
        try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        cachedSize = 0
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

    /// Tail recent WARNING/ERROR/FAULT lines for the bug-report sheet. Takes the
    /// write lock to avoid observing a partial flush from concurrent `record(...)`
    /// or racing with rotation. Lines truncated to `maxLineLength` so a pathological
    /// stack-trace can't blow past GitHub's issue-URL body ceiling downstream.
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
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            return nil
        }
        let url = directory.appendingPathComponent("runtime.log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        }
        // createDirectory/createFile only set permissions on creation — tighten
        // pre-existing installs (and any laxer rotated siblings) on every launch.
        try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: directory.path)
        try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        for index in 1...rotationKeepCount {
            let rotated = url.deletingPathExtension().appendingPathExtension("\(index).log")
            if fm.fileExists(atPath: rotated.path) {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: rotated.path)
            }
        }
        return url
    }
}
