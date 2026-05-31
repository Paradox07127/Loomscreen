#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Darwin
import Foundation

struct SteamCMDRunResult: Sendable {
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let killed: Bool
}

typealias SteamCMDProgressHandler = @Sendable (_ percent: Double, _ downloadedBytes: UInt64?, _ totalBytes: UInt64?) -> Void

struct SteamCMDDownloadProgress: Equatable, Sendable {
    let percent: Double
    let downloadedBytes: UInt64?
    let totalBytes: UInt64?
}

/// Executes SteamCMD (or any sibling diagnostic tool) in its own process
/// group so cancellation / timeouts can terminate SteamCMD's self-update
/// child processes alongside the parent. Plain `Process.terminate()` would
/// orphan the child workers.
actor SteamCMDProcessRunner {

    func run(
        binary: URL,
        args: [String],
        stdin: String?,
        timeout: TimeInterval,
        workingDirectory: URL?,
        onProgress: SteamCMDProgressHandler? = nil
    ) async -> SteamCMDRunResult {
        do {
            try Task.checkCancellation()
            let spawned = try Self.spawn(
                binary: binary,
                args: args,
                stdin: stdin,
                workingDirectory: workingDirectory
            )
            let processGroup = SteamCMDProcessGroup(pid: spawned.pid)
            return await withTaskCancellationHandler {
                await Self.awaitCompletion(
                    spawned: spawned,
                    timeout: timeout,
                    processGroup: processGroup,
                    onProgress: onProgress
                )
            } onCancel: {
                processGroup.terminate()
            }
        } catch is CancellationError {
            return SteamCMDRunResult(exitCode: nil, stdout: "", stderr: "", timedOut: false, killed: true)
        } catch {
            return SteamCMDRunResult(
                exitCode: nil,
                stdout: "",
                stderr: "Process launch failed: \(error.localizedDescription)",
                timedOut: false,
                killed: false
            )
        }
    }

    /// Parses a SteamCMD download status line such as
    /// `Update state (0x61) downloading, progress: 42.34 (12345 / 67890)`
    /// into percent + downloaded/total bytes. Returns nil for non-progress lines.
    nonisolated static func parseDownloadProgressLine(_ line: String) -> SteamCMDDownloadProgress? {
        guard let progressRange = line.range(of: "progress:") else { return nil }
        let tail = line[progressRange.upperBound...]

        // Preferred form with byte detail: `progress: 42.34 (12345 / 67890)`.
        if let bytesStart = tail.firstIndex(of: "("),
           let bytesEnd = tail[bytesStart...].firstIndex(of: ")") {
            let percentText = tail[..<bytesStart].trimmingCharacters(in: .whitespacesAndNewlines)
            let bytesText = tail[tail.index(after: bytesStart)..<bytesEnd]
            let byteParts = bytesText.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            if byteParts.count == 2,
               let percent = Double(percentText),
               let downloaded = UInt64(byteParts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
               let total = UInt64(byteParts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                return SteamCMDDownloadProgress(percent: percent, downloadedBytes: downloaded, totalBytes: total)
            }
        }

        // Percent-only fallback: `progress: 42.34` (SteamCMD frequently omits the
        // byte detail for workshop_download_item, which previously left the UI
        // stuck on an indeterminate spinner with no progress bar). The download
        // size for the label then comes from the item's known file size.
        let numericPrefix = tail.drop(while: { $0 == " " }).prefix(while: { $0.isNumber || $0 == "." })
        guard let percent = Double(numericPrefix), percent.isFinite, percent >= 0 else { return nil }
        return SteamCMDDownloadProgress(percent: percent, downloadedBytes: nil, totalBytes: nil)
    }

    // MARK: - Spawn

    private static func spawn(
        binary: URL,
        args: [String],
        stdin: String?,
        workingDirectory: URL?
    ) throws -> SteamCMDSpawnedProcess {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&fileActions), context: "posix_spawn_file_actions_init")
        try check(posix_spawnattr_init(&attributes), context: "posix_spawnattr_init")
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        let stdinRead = stdinPipe.fileHandleForReading.fileDescriptor
        let stdinWrite = stdinPipe.fileHandleForWriting.fileDescriptor
        let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = stderrPipe.fileHandleForWriting.fileDescriptor

        try check(posix_spawn_file_actions_adddup2(&fileActions, stdinRead, STDIN_FILENO), context: "dup stdin")
        try check(posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO), context: "dup stdout")
        try check(posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO), context: "dup stderr")
        for fd in [stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite] {
            try check(posix_spawn_file_actions_addclose(&fileActions, fd), context: "close fd \(fd)")
        }

        if let workingDirectory {
            let chdirResult = workingDirectory.path(percentEncoded: false).withCString { path in
                posix_spawn_file_actions_addchdir_np(&fileActions, path)
            }
            try check(chdirResult, context: "chdir")
        }

        // POSIX_SPAWN_CLOEXEC_DEFAULT closes every FD that doesn't have an
        // explicit `addopen` / `adddup2` action, so we never leak the app's
        // open sockets / files into the user-selected SteamCMD binary.
        let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        try check(posix_spawnattr_setflags(&attributes, spawnFlags), context: "set spawn flags")
        try check(posix_spawnattr_setpgroup(&attributes, 0), context: "set process group")

        var pid = pid_t(0)
        let argvStrings = [binary.path(percentEncoded: false)] + args
        let envStrings = sanitizedChildEnvironment()
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        let spawnResult = withCStringArray(argvStrings) { argv in
            withCStringArray(envStrings) { envp in
                binary.path(percentEncoded: false).withCString { path in
                    posix_spawn(&pid, path, &fileActions, &attributes, argv, envp)
                }
            }
        }

        guard spawnResult == 0 else {
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
            throw SteamCMDProcessRunnerError.spawnFailed(String(cString: strerror(spawnResult)))
        }

        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        if let stdin, let data = stdin.data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        return SteamCMDSpawnedProcess(
            pid: pid,
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )
    }

    private static func check(_ result: Int32, context: String) throws {
        guard result == 0 else {
            throw SteamCMDProcessRunnerError.spawnFailed("\(context): \(String(cString: strerror(result)))")
        }
    }

    /// Minimal, scrubbed environment for spawned tools (SteamCMD, codesign).
    /// We never hand the app's full environment to a child: `DYLD_*` is dropped
    /// (the SteamCMD Mach-O locates its own dylibs without it — verified), and
    /// agent sockets / tokens / proxy secrets are excluded. `HOME` is the
    /// sandbox container so SteamCMD's session + downloads stay container-local
    /// and match the user's pinned-`HOME` Terminal sign-in.
    private static func sanitizedChildEnvironment() -> [String: String] {
        [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            // Force a deterministic English UTF-8 locale so SteamCMD's status
            // lines parse the same regardless of the user's system locale,
            // rather than inheriting a launcher-controlled TMPDIR/LANG.
            "LANG": "en_US.UTF-8",
        ]
    }

    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> R
    ) rethrows -> R {
        var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        cStrings.append(nil)
        defer {
            for case let pointer? in cStrings {
                free(pointer)
            }
        }
        return try cStrings.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    // MARK: - Completion

    private static func awaitCompletion(
        spawned: SteamCMDSpawnedProcess,
        timeout: TimeInterval,
        processGroup: SteamCMDProcessGroup,
        onProgress: SteamCMDProgressHandler?
    ) async -> SteamCMDRunResult {
        let stdoutCapture = SteamCMDPipeCapture(handle: spawned.stdout, onProgress: onProgress)
        let stderrCapture = SteamCMDPipeCapture(handle: spawned.stderr)
        stdoutCapture.start()
        stderrCapture.start()

        let pid = spawned.pid
        let waitTask = Task.detached(priority: .utility) {
            waitForExit(pid: pid)
        }

        // Schedule a one-shot timeout that sends SIGTERM via the process
        // group when it fires. `waitpid` returns shortly after, so the
        // outer `await waitTask.value` becomes the single termination
        // point. The earlier `withTaskGroup` approach deadlocked here —
        // group exit waits for every child, but `waitpid` is a blocking
        // syscall that does not honor task cancellation.
        let clampedTimeout = max(0, timeout)
        let timeoutTask = Task<Void, Never>.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: UInt64(clampedTimeout * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            processGroup.terminate()
        }

        let exitCode = await waitTask.value
        timeoutTask.cancel()
        processGroup.markExited()

        let timedOut = !timeoutTask.isCancelled && processGroup.didTerminate
        let killed = processGroup.didTerminate

        stdoutCapture.waitForEOF(timeout: 1)
        stderrCapture.waitForEOF(timeout: 1)
        let stdout = stdoutCapture.string
        let stderr = stderrCapture.string
        stdoutCapture.stop()
        stderrCapture.stop()

        return SteamCMDRunResult(
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            killed: killed
        )
    }

    private static func waitForExit(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let waited = Darwin.waitpid(pid, &status, 0)
            if waited == pid {
                return decodeWaitStatus(status)
            }
            if waited == -1, errno == EINTR {
                continue
            }
            return nil
        }
    }

    private static func decodeWaitStatus(_ status: Int32) -> Int32? {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        if signal != 0x7f {
            return 128 + signal
        }
        return nil
    }
}

private struct SteamCMDSpawnedProcess {
    let pid: pid_t
    let stdout: FileHandle
    let stderr: FileHandle
}

private enum SteamCMDProcessRunnerError: Error, LocalizedError {
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let reason):
            return reason
        }
    }
}

private final class SteamCMDProcessGroup: @unchecked Sendable {
    let pid: pid_t

    private let lock = NSLock()
    private var terminated = false
    private var exited = false

    init(pid: pid_t) { self.pid = pid }

    var didTerminate: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminated
    }

    func markExited() {
        lock.lock(); exited = true; lock.unlock()
    }

    private var shouldEscalate: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminated && !exited
    }

    @discardableResult
    func terminate() -> Bool {
        lock.lock()
        let shouldTerminate = !terminated
        if shouldTerminate { terminated = true }
        lock.unlock()

        guard shouldTerminate else { return true }
        let groupID = -pid
        _ = Darwin.kill(groupID, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.shouldEscalate, Darwin.kill(groupID, 0) == 0 else { return }
            _ = Darwin.kill(groupID, SIGKILL)
        }
        return true
    }
}

private final class SteamCMDPipeCapture: @unchecked Sendable {
    private let handle: FileHandle
    private let onProgress: SteamCMDProgressHandler?
    private let lock = NSLock()
    private let eof = DispatchSemaphore(value: 0)
    private var data = Data()
    private var lineBuffer = ""
    private var didReachEOF = false

    init(handle: FileHandle, onProgress: SteamCMDProgressHandler? = nil) {
        self.handle = handle
        self.onProgress = onProgress
    }

    func start() {
        handle.readabilityHandler = { [weak self] fileHandle in
            guard let self else { return }
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                self.markEOF()
            } else {
                self.append(chunk)
            }
        }
    }

    func waitForEOF(timeout: TimeInterval) {
        lock.lock()
        let alreadyEOF = didReachEOF
        lock.unlock()
        guard !alreadyEOF else { return }
        _ = eof.wait(timeout: .now() + timeout)
    }

    func stop() {
        handle.readabilityHandler = nil
        try? handle.close()
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func append(_ chunk: Data) {
        let progress = appendAndParseProgress(chunk)
        publish(progress)
    }

    private func appendAndParseProgress(_ chunk: Data) -> SteamCMDDownloadProgress? {
        lock.lock()
        defer { lock.unlock() }

        data.append(chunk)
        guard onProgress != nil else { return nil }

        lineBuffer.append(String(decoding: chunk, as: UTF8.self))
        return drainCompletedProgressLines()
    }

    private func markEOF() {
        let progress: SteamCMDDownloadProgress?
        let shouldSignal: Bool

        lock.lock()
        if onProgress != nil, !lineBuffer.isEmpty {
            progress = SteamCMDProcessRunner.parseDownloadProgressLine(lineBuffer)
            lineBuffer.removeAll(keepingCapacity: true)
        } else {
            progress = nil
        }
        shouldSignal = !didReachEOF
        didReachEOF = true
        lock.unlock()

        publish(progress)
        if shouldSignal { eof.signal() }
    }

    /// Splits the accumulated buffer on newlines and returns the latest parsable
    /// progress line. Caller holds `lock`.
    private func drainCompletedProgressLines() -> SteamCMDDownloadProgress? {
        var latest: SteamCMDDownloadProgress?
        while let terminator = lineBuffer.rangeOfCharacter(from: .newlines) {
            let line = String(lineBuffer[..<terminator.lowerBound])
            lineBuffer.removeSubrange(lineBuffer.startIndex..<terminator.upperBound)
            if let progress = SteamCMDProcessRunner.parseDownloadProgressLine(line) {
                latest = progress
            }
        }

        if lineBuffer.count > 8192 {
            lineBuffer = String(lineBuffer.suffix(8192))
        }
        return latest
    }

    private func publish(_ progress: SteamCMDDownloadProgress?) {
        guard let progress else { return }
        onProgress?(progress.percent, progress.downloadedBytes, progress.totalBytes)
    }
}
#endif
