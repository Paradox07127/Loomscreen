import Foundation
import os

final class CodexAgentSource: MonitorDataSource {
    let sourceID = "codex"

    private static let activePollInterval: TimeInterval = 1.5
    private static let idlePollInterval: TimeInterval = 5
    private static let rescanInterval: TimeInterval = 10
    private static let endedRetention: TimeInterval = 2 * 60 * 60

    /// Lifecycle state touched by `start`/`stop`.
    private struct Lifecycle {
        var pollTask: Task<Void, Never>?
        var didStartSecurityScope = false
    }

    private let rootURL: URL
    private let cursorStore: MonitorTailCursorStore?
    private let usageLock = OSAllocatedUnfairLock(initialState: MonitorProviderUsage(costTodayUSD: nil, tokensToday: .zero))
    private let ledgerLock = OSAllocatedUnfairLock(initialState: MonitorUsageLedgerFragment())
    private let lifecycle = OSAllocatedUnfairLock(initialState: Lifecycle())

    init(rootURL: URL, cursorStore: MonitorTailCursorStore? = nil) {
        self.rootURL = rootURL
        self.cursorStore = cursorStore
    }

    func start(sink: any MonitorSnapshotSink) async {
        lifecycle.withLock { state in
            guard state.pollTask == nil else { return }
            state.didStartSecurityScope = rootURL.startAccessingSecurityScopedResource()
            state.pollTask = Task { [weak self] in
                await self?.run(sink: sink)
            }
        }
    }

    func stop() async {
        let (task, wasScoped) = lifecycle.withLock { state -> (Task<Void, Never>?, Bool) in
            let task = state.pollTask
            let scoped = state.didStartSecurityScope
            state.pollTask = nil
            state.didStartSecurityScope = false
            return (task, scoped)
        }
        guard let task else { return }
        task.cancel()
        await task.value
        cursorStore?.flush()
        if wasScoped {
            rootURL.stopAccessingSecurityScopedResource()
        }
    }

    func currentUsage() -> MonitorProviderUsage {
        usageLock.withLock { $0 }
    }

    private func run(sink: any MonitorSnapshotSink) async {
        let scanner = CodexSessionScanner(rootURL: rootURL)
        var readers: [URL: JSONLTailReader] = [:]
        var models: [URL: CodexSessionModel] = [:]
        var files: [CodexSessionScanner.SessionFile] = []
        var lastScan = Date.distantPast
        var waitTracker = MonitorFleetWaitTracker()
        let backfill = MonitorUsageBackfillCache()
        var burnWindow = MonitorBurnRateWindow()

        while !Task.isCancelled {
            let now = Date()
            var pollHadError = false

            if now.timeIntervalSince(lastScan) >= Self.rescanInterval {
                lastScan = now
                do {
                    files = try scanner.scan(now: now)
                    let currentURLs = Set(files.map(\.url))
                    readers = readers.filter { currentURLs.contains($0.key) }
                    models = models.filter { currentURLs.contains($0.key) }
                    await sink.updateHealth(Self.health(state: "ok", detail: nil, at: now))
                } catch CodexSessionScanner.ScanError.unauthorized {
                    files.removeAll()
                    readers.removeAll()
                    models.removeAll()
                    await sink.updateHealth(Self.health(state: "unauthorized", detail: "Grant access to ~/.codex", at: now))
                } catch {
                    pollHadError = true
                    await sink.updateHealth(Self.health(state: "error", detail: "Failed to scan Codex sessions", at: now))
                }
            }

            for file in files {
                let reader: JSONLTailReader
                if let existingReader = readers[file.url] {
                    reader = existingReader
                } else {
                    let storedCursor = cursorStore?.state(for: file.url)
                    let storedAggregate = cursorStore?.aggregate(for: file.url, provider: .codex)
                    let restoredModel = storedCursor.flatMap { _ in
                        storedAggregate.flatMap(CodexSessionModel.restore)
                    }
                    reader = JSONLTailReader(
                        url: file.url,
                        resumeFrom: restoredModel == nil ? nil : storedCursor
                    )
                    readers[file.url] = reader
                    if let restoredModel {
                        models[file.url] = restoredModel
                    } else if storedAggregate != nil {
                        cursorStore?.removeAggregate(for: file.url)
                    }
                }

                do {
                    let outcome = try reader.poll()
                    if outcome.fileVanished {
                        readers[file.url] = nil
                        models[file.url] = nil
                        cursorStore?.remove(for: file.url)
                        continue
                    }
                    if outcome.didRotate {
                        models[file.url] = CodexSessionModel()
                        cursorStore?.removeAggregate(for: file.url)
                    }
                    if !outcome.newLines.isEmpty {
                        var model = models[file.url] ?? CodexSessionModel()
                        for line in outcome.newLines {
                            model.ingest(line)
                        }
                        models[file.url] = model
                    }
                    if let cursorState = reader.cursorState {
                        if let model = models[file.url] {
                            cursorStore?.set(cursorState, aggregate: model.snapshotState(), for: file.url)
                        } else {
                            cursorStore?.set(cursorState, for: file.url)
                        }
                    }
                } catch {
                    pollHadError = true
                }
            }

            let sessions = Self.sessionStates(modelsByURL: models, files: files, now: now, waitTracker: &waitTracker)
            let usage = Self.usageSnapshot(from: Array(models.values), now: now)
            setCurrentUsage(usage)
            refreshLedger(models: models, files: files, backfill: backfill, burnWindow: &burnWindow, usage: usage, now: now)
            await sink.updateAgents(sourceID: sourceID, sessions: sessions)
            if pollHadError {
                await sink.updateHealth(Self.health(state: "error", detail: "Failed to read Codex sessions", at: now))
            }

            let hasLiveSession = sessions.contains { $0.status == .running || $0.status == .needsInput || $0.status == .idle }
            let interval = hasLiveSession ? Self.activePollInterval : Self.idlePollInterval
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func setCurrentUsage(_ usage: MonitorProviderUsage) {
        usageLock.withLock { current in
            current = usage
        }
    }

    /// Codex usage-ledger fragment (per-model + per-day history + burn rates),
    /// merged by the integrator with the Claude fragment. See contract-gap note.
    func currentUsageLedger() -> MonitorUsageLedgerFragment {
        ledgerLock.withLock { $0 }
    }

    /// Refresh the cached ledger fragment: bounded 14-day backfill (≤ every 5 min)
    /// over the Codex session tree plus the windowed burn rate off today's totals.
    private func refreshLedger(
        models: [URL: CodexSessionModel],
        files: [CodexSessionScanner.SessionFile],
        backfill: MonitorUsageBackfillCache,
        burnWindow: inout MonitorBurnRateWindow,
        usage: MonitorProviderUsage,
        now: Date
    ) {
        let buckets: [MonitorFileUsageBuckets]
        if backfill.shouldRefresh(now: now) {
            buckets = backfill.refresh(files: Self.ledgerFileRefs(rootURL: rootURL, now: now), now: now)
        } else {
            buckets = backfill.cachedBuckets()
        }
        let today = usage.tokensToday ?? .zero
        let cumulative = today.input + today.output + today.cacheRead + today.cacheWrite
        burnWindow.record(at: now.timeIntervalSince1970, cumulativeTokens: cumulative, cumulativeCost: usage.costTodayUSD)
        let rates = burnWindow.rates()
        let fragment = MonitorUsageLedgerFragment(
            fileBuckets: buckets,
            tokensPerHour: rates.tokensPerHour,
            costPerHour: rates.costPerHour
        )
        ledgerLock.withLock { $0 = fragment }
    }

    /// Enumerate `rollout-*.jsonl` inside the ledger day window, with size for the memo fingerprint.
    static let ledgerFileLimit = 400

    static func ledgerFileRefs(rootURL: URL, now: Date) -> [MonitorUsageFileRef] {
        let sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        let cutoff = now.addingTimeInterval(-TimeInterval(MonitorUsageRollup.dayWindow) * 24 * 3600)
        let cutoffDay = Calendar.current.startOfDay(for: cutoff)
        let dayURLs = dateShardedDayDirectories(under: sessionsURL, onOrAfter: cutoffDay)

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let fileManager = FileManager.default
        var refs: [MonitorUsageFileRef] = []
        for dayURL in dayURLs {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: dayURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries {
                guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let mtime = values.contentModificationDate, mtime >= cutoff else { continue }
                refs.append(MonitorUsageFileRef(
                    url: url, provider: .codex,
                    size: UInt64(values.fileSize ?? 0), mtime: mtime
                ))
            }
        }
        guard refs.count > ledgerFileLimit else { return refs }
        return Array(refs.sorted { $0.mtime > $1.mtime }.prefix(ledgerFileLimit))
    }

    /// Resolve the `sessions/YYYY/MM/DD` leaf directories whose date is on or after `cutoffDay`, pruning older year/month/day shards without descending.
    private static func dateShardedDayDirectories(under sessionsURL: URL, onOrAfter cutoffDay: Date) -> [URL] {
        let calendar = Calendar.current
        let cutoff = calendar.dateComponents([.year, .month, .day], from: cutoffDay)
        let fileManager = FileManager.default

        func children(_ url: URL) -> [URL] {
            (try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? []
        }

        var days: [URL] = []
        for yearURL in children(sessionsURL) {
            let year = Int(yearURL.lastPathComponent)
            if let year, let cutoffYear = cutoff.year, year < cutoffYear { continue }
            for monthURL in children(yearURL) {
                let month = Int(monthURL.lastPathComponent)
                if let year, let month, let cutoffYear = cutoff.year, let cutoffMonth = cutoff.month,
                   year == cutoffYear, month < cutoffMonth { continue }
                for dayURL in children(monthURL) {
                    if let year, let month, let day = Int(dayURL.lastPathComponent),
                       let dayDate = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                       dayDate < cutoffDay { continue }
                    days.append(dayURL)
                }
            }
        }
        return days
    }

    /// Overload retained for existing tests that don't exercise the wait clock.
    static func sessionStates(
        modelsByURL: [URL: CodexSessionModel],
        files: [CodexSessionScanner.SessionFile],
        now: Date
    ) -> [MonitorAgentSessionState] {
        var tracker = MonitorFleetWaitTracker()
        return sessionStates(modelsByURL: modelsByURL, files: files, now: now, waitTracker: &tracker)
    }

    static func sessionStates(
        modelsByURL: [URL: CodexSessionModel],
        files: [CodexSessionScanner.SessionFile],
        now: Date,
        waitTracker: inout MonitorFleetWaitTracker
    ) -> [MonitorAgentSessionState] {
        let states = files.compactMap { file -> MonitorAgentSessionState? in
            guard let model = modelsByURL[file.url],
                  var state = model.sessionState(
                    now: now,
                    processAlive: file.processAlive,
                    fallbackSessionId: fallbackSessionId(for: file.url),
                    fallbackProjectName: "Codex"
                  ) else {
                return nil
            }
            state.waitSince = waitTracker.waitSince(
                sessionID: state.id,
                status: state.status,
                eventTime: state.lastEventAt
            )

            if state.status == .ended,
               now.timeIntervalSince(Date(timeIntervalSince1970: state.lastEventAt)) > endedRetention {
                return nil
            }
            return state
        }
        .sorted { lhs, rhs in
            if lhs.lastEventAt != rhs.lastEventAt {
                return lhs.lastEventAt > rhs.lastEventAt
            }
            return lhs.id < rhs.id
        }
        waitTracker.retainOnly(Set(states.map(\.id)))
        return states
    }

    static func usageSnapshot(
        from models: [CodexSessionModel],
        now: Date,
        calendar: Calendar = .current
    ) -> MonitorProviderUsage {
        let tokens = models.reduce(MonitorTokenTotals.zero) { partial, model in
            guard let lastEventAt = model.lastEventAt,
                  calendar.isDate(lastEventAt, inSameDayAs: now) else {
                return partial
            }
            return partial + model.tokens
        }
        return MonitorProviderUsage(costTodayUSD: nil, tokensToday: tokens)
    }

    private static func fallbackSessionId(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if stem.hasPrefix("rollout-") {
            return String(stem.dropFirst("rollout-".count))
        }
        return stem.isEmpty ? UUID().uuidString : stem
    }

    private static func health(state: String, detail: String?, at date: Date) -> MonitorSourceHealth {
        MonitorSourceHealth(
            sourceID: "codex",
            state: state,
            detail: detail,
            lastUpdateAt: date.timeIntervalSince1970
        )
    }
}
