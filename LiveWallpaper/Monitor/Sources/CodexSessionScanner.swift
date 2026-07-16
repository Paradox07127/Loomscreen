import Darwin
import Foundation

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
    /// Compatibility budgets for layouts that do not use
    /// `sessions/YYYY/MM/DD`. Top-level discovery is deliberately separate from
    /// descendant traversal so neither phase can hide unbounded work in the
    /// other's allowance.
    private static let fallbackTopLevelEntryLimit = 96
    private static let fallbackDescendantEntryLimit = 256
    private static let fallbackRootLimit = 32
    private static let fallbackDepthLimit = 3

    let rootURL: URL
    private let processProbe: @Sendable () -> Bool
    private let visitObserver: (@Sendable (URL) -> Void)?

    init(
        rootURL: URL,
        processProbe: @escaping @Sendable () -> Bool = { CodexProcessProbe.isCodexRunning() },
        visitObserver: (@Sendable (URL) -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.processProbe = processProbe
        self.visitObserver = visitObserver
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
        guard let sessionsValues = try? sessionsURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
            sessionsValues.isDirectory == true,
            sessionsValues.isSymbolicLink != true else {
            throw ScanError.unauthorized
        }

        let cutoff = now.addingTimeInterval(-Self.scanWindow)
        let candidates = try candidateFiles(
            under: sessionsURL,
            cutoff: cutoff,
            now: now,
            fileManager: fileManager
        )

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

    /// Visits only the calendar-day leaves covered by the 48-hour window. A
    /// 48-hour interval can touch three civil days (and DST can change their
    /// duration), so derive the leaves with Calendar rather than subtracting a
    /// fixed number of folder names.
    private func candidateFiles(
        under sessionsURL: URL,
        cutoff: Date,
        now: Date,
        fileManager: FileManager
    ) throws -> [(url: URL, modificationDate: Date)] {
        let fileKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        var candidates: [URL: Date] = [:]

        func consider(_ url: URL, reportVisit: Bool = true) {
            if reportVisit {
                visitObserver?(url)
            }
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: fileKeys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate >= cutoff else {
                return
            }
            candidates[url.standardizedFileURL] = modificationDate
        }

        for dayURL in Self.inWindowDayDirectories(
            under: sessionsURL,
            cutoff: cutoff,
            now: now
        ) {
            guard Self.isNonSymlinkDirectory(dayURL, beneath: sessionsURL) else { continue }
            visitObserver?(dayURL)
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: dayURL,
                    includingPropertiesForKeys: Array(fileKeys),
                    options: [.skipsHiddenFiles]
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                // One unreadable shard must not hide other recent sessions.
                continue
            }
            for child in children {
                consider(child)
            }
        }

        // Older Codex builds or hand-migrated stores may have a non-date
        // layout. DirectoryEnumerator is lazy, and
        // `skipsSubdirectoryDescendants` makes this a genuinely shallow scan;
        // unlike `contentsOfDirectory`, it does not materialize and sort the
        // entire directory before the budget can be enforced. Every raw entry
        // pulled from the enumerator consumes the budget before filtering, so
        // hidden, malformed, canonical-year, and symlink entries cannot make
        // the work counter under-report the traversal. This is intentionally a
        // best-effort compatibility sample: an unknown legacy root beyond the
        // first 96 entries is traded for a strict resource ceiling.
        guard let topLevelEnumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: Array(fileKeys),
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in false }
        ) else {
            throw ScanError.unauthorized
        }

        let sessionsComponents = sessionsURL.standardizedFileURL.pathComponents.count
        var topLevelEntries = 0
        var fallbackRoots: [(url: URL, values: URLResourceValues)] = []
        while topLevelEntries < Self.fallbackTopLevelEntryLimit,
              let url = topLevelEnumerator.nextObject() as? URL {
            topLevelEntries += 1
            visitObserver?(url)

            guard let values = try? url.resourceValues(forKeys: fileKeys),
                  values.isSymbolicLink != true,
                  !url.lastPathComponent.hasPrefix("."),
                  !(values.isDirectory == true && Self.isCanonicalYear(url.lastPathComponent)),
                  values.isDirectory == true
                  || (values.isRegularFile == true
                      && url.lastPathComponent.hasPrefix("rollout-")
                      && url.pathExtension == "jsonl") else {
                continue
            }
            if fallbackRoots.count < Self.fallbackRootLimit {
                fallbackRoots.append((url, values))
            }
        }

        var fallbackDescendantEntries = 0
        var walkers: [(enumerator: FileManager.DirectoryEnumerator, exhausted: Bool)] = []
        for root in fallbackRoots {
            if root.values.isDirectory == true {
                if let enumerator = fileManager.enumerator(
                    at: root.url,
                    includingPropertiesForKeys: Array(fileKeys),
                    options: [],
                    errorHandler: { _, _ in true }
                ) {
                    walkers.append((enumerator, false))
                }
            } else {
                consider(root.url, reportVisit: false)
            }
        }

        // Round-robin across unexpected roots. A single huge legacy directory
        // cannot consume the entire compatibility budget before a neighboring
        // root containing the current active session is sampled. This still
        // runs beside the date-shard scan because migrated stores can contain
        // both layouts; the bounded legacy candidates participate in the same
        // final top-40 ordering.
        while fallbackDescendantEntries < Self.fallbackDescendantEntryLimit,
              walkers.contains(where: { !$0.exhausted }) {
            for index in walkers.indices
                where fallbackDescendantEntries < Self.fallbackDescendantEntryLimit {
                guard !walkers[index].exhausted else { continue }
                let enumerator = walkers[index].enumerator
                guard let url = enumerator.nextObject() as? URL else {
                    walkers[index].exhausted = true
                    continue
                }

                fallbackDescendantEntries += 1
                visitObserver?(url)
                let values = try? url.resourceValues(forKeys: fileKeys)
                let depth = url.standardizedFileURL.pathComponents.count - sessionsComponents
                if values?.isSymbolicLink == true || url.lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }
                if values?.isDirectory == true {
                    if depth >= Self.fallbackDepthLimit {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                consider(url, reportVisit: false)
            }
        }

        return candidates.map { (url: $0.key, modificationDate: $0.value) }
    }

    private static func inWindowDayDirectories(
        under sessionsURL: URL,
        cutoff: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> [URL] {
        var day = calendar.startOfDay(for: cutoff)
        let finalDay = calendar.startOfDay(for: now)
        var result: [URL] = []

        while day <= finalDay {
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            if let year = components.year,
               let month = components.month,
               let dayNumber = components.day {
                result.append(
                    sessionsURL
                        .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", dayNumber), isDirectory: true)
                )
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                  next > day else { break }
            day = next
        }
        return result
    }

    /// Direct date-leaf access must not follow a symlink out of the granted
    /// Codex root. Validate each existing path component from year through day.
    private static func isNonSymlinkDirectory(_ url: URL, beneath root: URL) -> Bool {
        let root = root.standardizedFileURL
        let target = url.standardizedFileURL
        guard target.pathComponents.starts(with: root.pathComponents) else { return false }

        var current = root
        for component in target.pathComponents.dropFirst(root.pathComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            guard let values = try? current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                return false
            }
        }
        return true
    }

    private static func isCanonicalYear(_ component: String) -> Bool {
        component.count == 4 && component.allSatisfy { $0.isNumber }
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
