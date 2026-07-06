import Foundation
import Darwin

struct CodexSessionScanner: Sendable {
    struct SessionFile: Sendable, Equatable {
        var url: URL
        var modificationDate: Date
        var processAlive: Bool
    }

    enum ScanError: Error, Equatable {
        case unauthorized
    }

    private static let scanWindow: TimeInterval = 48 * 60 * 60
    private static let liveFileWindow: TimeInterval = 10 * 60
    private static let maxFiles = 40

    let rootURL: URL
    private let processProbe: @Sendable () -> Bool

    init(
        rootURL: URL,
        processProbe: @escaping @Sendable () -> Bool = { CodexProcessProbe.isCodexRunning() }
    ) {
        self.rootURL = rootURL
        self.processProbe = processProbe
    }

    func scan(now: Date = Date()) throws -> [SessionFile] {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        let rootPath = rootURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScanError.unauthorized
        }

        let sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        var sessionsIsDirectory = ObjCBool(false)
        let sessionsPath = sessionsURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: sessionsPath, isDirectory: &sessionsIsDirectory) else {
            return []
        }
        guard sessionsIsDirectory.boolValue else { return [] }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            throw ScanError.unauthorized
        }

        let cutoff = now.addingTimeInterval(-Self.scanWindow)
        var candidates: [(url: URL, modificationDate: Date)] = []

        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" else {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate >= cutoff else {
                continue
            }
            candidates.append((url, modificationDate))
        }

        let codexRunning = processProbe()
        return candidates
            .sorted { lhs, rhs in
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate > rhs.modificationDate
                }
                return lhs.url.path(percentEncoded: false) < rhs.url.path(percentEncoded: false)
            }
            .prefix(Self.maxFiles)
            .map { candidate in
                SessionFile(
                    url: candidate.url,
                    modificationDate: candidate.modificationDate,
                    processAlive: codexRunning && candidate.modificationDate >= now.addingTimeInterval(-Self.liveFileWindow)
                )
            }
    }
}

private enum CodexProcessProbe {
    private static let pathBufferSize = 4096

    static func isCodexRunning() -> Bool {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return false }

        var pids = [Int32](repeating: 0, count: Int(capacity))
        let byteCount = proc_listallpids(&pids, capacity * Int32(MemoryLayout<Int32>.stride))
        guard byteCount > 0 else { return false }
        let count = min(Int(byteCount) / MemoryLayout<Int32>.stride, pids.count)

        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            if executableBasename(pid: pid) == "codex" {
                return true
            }
        }
        return false
    }

    private static func executableBasename(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        let length = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
