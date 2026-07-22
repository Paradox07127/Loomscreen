import Foundation

/// Result of a single `JSONLTailReader.poll()`.
struct TailPollOutcome {
    var newLines: [Data] = []
    var didRotate = false
    var fileVanished = false
}

/// Incremental line-oriented tail reader for append-mostly JSONL transcripts.
final class JSONLTailReader {
    /// True when the first poll of an oversized file skipped the head and began
    /// mid-stream; callers should treat any derived aggregates as estimates.
    private(set) var startedMidFile = false

    private let url: URL
    private let resumeState: TailCursorState?

    private static let maxBytesPerPoll = 1 << 20            // ~1 MB
    // Full-scan threshold: files at or below this start from offset 0.
    private static let fullReadCeiling: UInt64 = 20 << 20   // 20 MB
    private static let midFileTailWindow: UInt64 = 5 << 20  // 5 MB
    private static let maxPendingBytes = 2 << 20            // 2 MB

    private var offset: UInt64 = 0
    private var committedOffset: UInt64 = 0
    private var lastSize: UInt64 = 0
    private var lastInode: UInt64 = 0
    private var pending = Data()
    private var didPrime = false
    private var didStat = false
    // When a mid-file start lands inside a line, the leading fragment up to the
    // first newline must be discarded exactly once before lines are trustworthy.
    private var needsLeadingResync = false

    var cursorState: TailCursorState? {
        guard didStat, !needsLeadingResync else { return nil }
        return TailCursorState(inode: lastInode, size: lastSize, offset: committedOffset)
    }

    convenience init(url: URL) {
        self.init(url: url, resumeFrom: nil)
    }

    init(url: URL, resumeFrom state: TailCursorState?) {
        self.url = url
        self.resumeState = state
    }

    func poll() throws -> TailPollOutcome {
        var outcome = TailPollOutcome()

        let stat: FileStat
        do {
            stat = try Self.statFile(url)
        } catch let error as TailError where error == .vanished {
            outcome.fileVanished = true
            reset()
            return outcome
        }
        didStat = true

        if !didPrime {
            didPrime = true
            lastInode = stat.inode
            lastSize = stat.size
            if let resumeState {
                if resumeState.inode == stat.inode,
                   stat.size >= resumeState.offset,
                   resumeState.size <= stat.size {
                    offset = resumeState.offset
                    committedOffset = resumeState.offset
                } else {
                    outcome.didRotate = true
                    offset = 0
                    committedOffset = 0
                }
            } else if stat.size > Self.fullReadCeiling {
                offset = stat.size - Self.midFileTailWindow
                committedOffset = offset
                startedMidFile = true
                needsLeadingResync = true
            } else {
                offset = 0
                committedOffset = 0
            }
        } else if stat.inode != lastInode || stat.size < lastSize {
            outcome.didRotate = true
            offset = 0
            committedOffset = 0
            pending.removeAll(keepingCapacity: true)
            needsLeadingResync = false
            lastInode = stat.inode
        }
        lastSize = stat.size

        guard stat.size > offset else { return outcome }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var budget = Self.maxBytesPerPoll
        while budget > 0, offset < stat.size {
            let want = min(UInt64(budget), stat.size - offset)
            guard let chunk = try handle.read(upToCount: Int(want)), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            budget -= chunk.count

            pending.append(chunk)
            extractLines(into: &outcome)
            updateCommittedOffset()
        }

        return outcome
    }

    // MARK: - Private

    private func extractLines(into outcome: inout TailPollOutcome) {
        if needsLeadingResync {
            guard let nl = pending.firstIndex(of: 0x0A) else {
                if pending.count > Self.maxPendingBytes {
                    pending.removeAll(keepingCapacity: true)
                }
                return
            }
            pending.removeSubrange(pending.startIndex...nl)
            needsLeadingResync = false
        }

        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            if !line.isEmpty {
                outcome.newLines.append(Data(line))
            }
            pending.removeSubrange(pending.startIndex...nl)
        }

        if pending.count > Self.maxPendingBytes {
            pending.removeAll(keepingCapacity: true)
        }
    }

    private func updateCommittedOffset() {
        guard !pending.isEmpty else {
            committedOffset = offset
            return
        }
        let pendingCount = UInt64(pending.count)
        committedOffset = offset >= pendingCount ? offset - pendingCount : 0
    }

    private func reset() {
        offset = 0
        committedOffset = 0
        lastSize = 0
        lastInode = 0
        pending.removeAll(keepingCapacity: true)
        didPrime = false
        didStat = false
        startedMidFile = false
        needsLeadingResync = false
    }

    private struct FileStat {
        var inode: UInt64
        var size: UInt64
    }

    private enum TailError: Error, Equatable {
        case vanished
        case statFailed(Int32)
    }

    private static func statFile(_ url: URL) throws -> FileStat {
        let statSyscall: (UnsafePointer<CChar>?, UnsafeMutablePointer<stat>?) -> Int32 = stat
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { rep -> Int32 in
            guard let rep else { return -1 }
            return statSyscall(rep, &info)
        }
        if result != 0 {
            if errno == ENOENT { throw TailError.vanished }
            throw TailError.statFailed(errno)
        }
        return FileStat(inode: UInt64(info.st_ino), size: UInt64(info.st_size))
    }
}
