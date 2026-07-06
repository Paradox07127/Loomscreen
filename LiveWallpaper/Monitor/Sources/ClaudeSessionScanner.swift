import Foundation
import Darwin

/// A transcript file worth tailing, discovered under `projects/*/`.
struct SessionFileCandidate: Equatable {
    var url: URL
    var sessionId: String          // filename stem (the session UUID)
    var projectDirName: String     // encoded cwd, e.g. "-Users-me-proj"
    var modifiedAt: Date
    var sizeBytes: UInt64
}

/// A `sessions/<PID>.json` process descriptor.
struct ClaudePIDDescriptor: Equatable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    var kind: String?
    var name: String?
    /// Wall-clock the CLI recorded at launch (epoch seconds; the file stores ms).
    var startedAt: Date?
}

/// Filesystem discovery + process-liveness for Claude Code sessions. All methods
/// are read-only against the user-granted `~/.claude` root.
struct ClaudeSessionScanner {
    let rootURL: URL

    /// Reject descriptors whose live process start time drifts from the recorded
    /// `startedAt` by more than this — cheap defense against PID reuse.
    private static let pidReuseSlack: TimeInterval = 5

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: - Transcript discovery

    /// List `projects/*/*.jsonl` transcripts modified within `lookback`, newest
    /// first, capped at `limit`. Throws only if the projects root is unreadable
    /// (surfaced upstream as an "unauthorized" health state).
    func discoverTranscripts(
        now: Date = Date(),
        lookback: TimeInterval = 48 * 3600,
        limit: Int = 40
    ) throws -> [SessionFileCandidate] {
        let projectsRoot = rootURL.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default

        let projectDirs = try fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let cutoff = now.addingTimeInterval(-lookback)
        var candidates: [SessionFileCandidate] = []

        for dir in projectDirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let projectDirName = dir.lastPathComponent

            let files = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = values?.contentModificationDate ?? .distantPast
                guard mtime >= cutoff else { continue }
                candidates.append(SessionFileCandidate(
                    url: file,
                    sessionId: file.deletingPathExtension().lastPathComponent,
                    projectDirName: projectDirName,
                    modifiedAt: mtime,
                    sizeBytes: UInt64(values?.fileSize ?? 0)
                ))
            }
        }

        candidates.sort { $0.modifiedAt > $1.modifiedAt }
        if candidates.count > limit {
            candidates = Array(candidates.prefix(limit))
        }
        return candidates
    }

    // MARK: - PID descriptors

    /// Parse every `sessions/<PID>.json`. Missing dir ⇒ empty (not an error);
    /// malformed individual files are skipped.
    func loadPIDDescriptors() -> [ClaudePIDDescriptor] {
        let sessionsRoot = rootURL.appendingPathComponent("sessions", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [ClaudePIDDescriptor] = []
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let pid = (object["pid"] as? Int).map(Int32.init) ?? (object["pid"] as? NSNumber).map({ $0.int32Value }),
                let sessionId = object["sessionId"] as? String
            else { continue }

            var startedAt: Date?
            if let ms = object["startedAt"] as? Double {
                startedAt = Date(timeIntervalSince1970: ms / 1000)
            } else if let ms = object["startedAt"] as? Int {
                startedAt = Date(timeIntervalSince1970: Double(ms) / 1000)
            }

            result.append(ClaudePIDDescriptor(
                pid: pid,
                sessionId: sessionId,
                cwd: object["cwd"] as? String,
                kind: object["kind"] as? String,
                name: object["name"] as? String,
                startedAt: startedAt
            ))
        }
        return result
    }

    /// Map sessionId → alive?. A descriptor is alive when its PID exists AND,
    /// when both timestamps are available, the process start time matches the
    /// recorded `startedAt` (guarding against PID reuse). If a sessionId has
    /// multiple descriptors, alive wins.
    func livenessBySession(_ descriptors: [ClaudePIDDescriptor]) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for descriptor in descriptors {
            let alive = isAlive(descriptor)
            map[descriptor.sessionId] = (map[descriptor.sessionId] ?? false) || alive
        }
        return map
    }

    /// Liveness for one descriptor: `kill(pid, 0) == 0`, plus a best-effort start
    /// time cross-check when the OS can supply it.
    func isAlive(_ descriptor: ClaudePIDDescriptor) -> Bool {
        guard descriptor.pid > 0 else { return false }
        if kill(descriptor.pid, 0) != 0 {
            // ESRCH ⇒ no such process; EPERM ⇒ exists but not ours (still alive).
            return errno == EPERM
        }
        guard
            let recorded = descriptor.startedAt,
            let actual = Self.processStartTime(pid: descriptor.pid)
        else {
            return true   // can't verify start time ⇒ trust kill(0).
        }
        return abs(actual.timeIntervalSince(recorded)) <= Self.pidReuseSlack
    }

    /// Process start time via `sysctl(KERN_PROC_PID)`. Best-effort — returns nil
    /// on any failure so callers fall back to the kill(0) result.
    static func processStartTime(pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec != 0 || tv.tv_usec != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}
