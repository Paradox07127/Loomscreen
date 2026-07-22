import Foundation

/// Monitor data source for Claude Code sessions.
final class ClaudeAgentSource: MonitorDataSource {
    let sourceID = "claude"

    struct TailBootstrap {
        let reader: JSONLTailReader
        let restoredModel: ClaudeSessionModel?
    }

    private let engine: Engine

    init(rootURL: URL, cursorStore: MonitorTailCursorStore? = nil) {
        self.engine = Engine(rootURL: rootURL, cursorStore: cursorStore)
    }

    /// Reconnects the scanner-owned session identity to a privacy-minimized durable aggregate.
    static func makeTailBootstrap(
        url: URL,
        candidateSessionID: String,
        storedCursor: TailCursorState?,
        storedAggregate: SessionAggregateState?
    ) -> TailBootstrap {
        guard let storedCursor,
              let storedAggregate,
              let restoredModel = ClaudeSessionModel.restore(
                  from: storedAggregate,
                  sessionId: candidateSessionID
              ) else {
            return TailBootstrap(reader: JSONLTailReader(url: url, resumeFrom: nil), restoredModel: nil)
        }
        return TailBootstrap(
            reader: JSONLTailReader(url: url, resumeFrom: storedCursor),
            restoredModel: restoredModel
        )
    }

    func start(sink: any MonitorSnapshotSink) async {
        await engine.start(sink: sink)
    }

    func stop() async {
        await engine.stop()
    }

    /// Claude-only usage for today.
    func currentUsage() async -> MonitorProviderUsage {
        await engine.currentUsage()
    }

    /// Claude-only usage-ledger fragment (per-model + per-day history over the trailing 14-day window, plus burn rates).
    func currentUsageLedger() async -> MonitorUsageLedgerFragment {
        await engine.currentUsageLedger()
    }
}

/// Cross-provider usage-ledger fragment a source contributes: per-file daily buckets (already extracted, ready to roll up) plus its windowed burn rates.
struct MonitorUsageLedgerFragment: Sendable, Equatable {
    var fileBuckets: [MonitorFileUsageBuckets] = []
    var tokensPerHour: Double?
    var costPerHour: Double?
}

// MARK: - Engine (all mutable state, isolated)

private actor Engine {
    private let rootURL: URL
    private let scanner: ClaudeSessionScanner
    private let cursorStore: MonitorTailCursorStore?

    private var sink: (any MonitorSnapshotSink)?
    private var pollTask: Task<Void, Never>?

    private var readers: [String: JSONLTailReader] = [:]
    private var models: [String: ClaudeSessionModel] = [:]
    private var sourceURLs: [String: URL] = [:]

    private var lastScan: Date = .distantPast
    private var consecutiveIOFailures = 0

    private var waitTracker = MonitorFleetWaitTracker()
    private let backfill = MonitorUsageBackfillCache()
    private var burnWindow = MonitorBurnRateWindow()

    // Cadence.
    private static let activeInterval: TimeInterval = 1.5
    private static let idleInterval: TimeInterval = 5
    private static let rescanInterval: TimeInterval = 10
    // Drop ended sessions from the pushed list once this stale.
    private static let endedRetention: TimeInterval = 2 * 3600
    private static let ioFailureThreshold = 3

    init(rootURL: URL, cursorStore: MonitorTailCursorStore?) {
        self.rootURL = rootURL
        self.scanner = ClaudeSessionScanner(rootURL: rootURL)
        self.cursorStore = cursorStore
    }

    func start(sink: any MonitorSnapshotSink) {
        self.sink = sink
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() async {
        let task = pollTask
        pollTask = nil
        task?.cancel()
        // No producer may mutate the cursor generation after the termination flush snapshots it.
        if let task { await task.value }
        sink = nil
        readers.removeAll()
        models.removeAll()
        sourceURLs.removeAll()
        cursorStore?.flush()
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let liveCount = await tick()
            let interval = liveCount > 0 ? Self.activeInterval : Self.idleInterval
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// One poll cycle. Returns the number of live sessions (drives cadence).
    private func tick() async -> Int {
        let now = Date()

        if now.timeIntervalSince(lastScan) >= Self.rescanInterval {
            lastScan = now
            do {
                try rescan(now: now)
                consecutiveIOFailures = 0
            } catch {
                // Projects root unreadable ⇒ permission problem.
                await pushHealth(state: "unauthorized", detail: "cannot read ~/.claude/projects", now: now)
                return 0
            }
        }

        let descriptors = scanner.loadPIDDescriptors()
        let liveness = scanner.livenessBySession(descriptors)

        var pollFailed = false
        for (sessionId, reader) in readers {
            do {
                let outcome = try reader.poll()
                if outcome.fileVanished {
                    readers[sessionId] = nil
                    if let url = sourceURLs[sessionId] {
                        cursorStore?.remove(for: url)
                    }
                    continue
                }
                if outcome.didRotate {
                    models[sessionId] = ClaudeSessionModel(sessionId: sessionId)
                    if let url = sourceURLs[sessionId] {
                        cursorStore?.removeAggregate(for: url)
                    }
                }
                if !outcome.newLines.isEmpty {
                    var model = models[sessionId] ?? ClaudeSessionModel(sessionId: sessionId)
                    for data in outcome.newLines {
                        if let line = ClaudeTranscriptLine(data: data) {
                            model.ingest(line)
                        }
                    }
                    models[sessionId] = model
                }
                if let url = sourceURLs[sessionId],
                   let cursorState = reader.cursorState {
                    if let model = models[sessionId] {
                        cursorStore?.set(cursorState, aggregate: model.snapshotState(), for: url)
                    } else {
                        cursorStore?.set(cursorState, for: url)
                    }
                }
            } catch {
                pollFailed = true
            }
        }

        let sessions = composeSessions(now: now, liveness: liveness)
        await pushAgents(sessions)

        if pollFailed {
            consecutiveIOFailures += 1
            if consecutiveIOFailures >= Self.ioFailureThreshold {
                await pushHealth(state: "error", detail: "transcript read failures", now: now)
            } else {
                await pushHealth(state: "ok", detail: nil, now: now)
            }
        } else {
            consecutiveIOFailures = 0
            await pushHealth(state: "ok", detail: nil, now: now)
        }

        return sessions.filter { $0.processAlive }.count
    }

    private func rescan(now: Date) throws {
        let candidates = try scanner.discoverTranscripts(now: now)
        let discovered = Set(candidates.map(\.sessionId))

        for candidate in candidates where readers[candidate.sessionId] == nil {
            let storedCursor = cursorStore?.state(for: candidate.url)
            let storedAggregate = cursorStore?.aggregate(for: candidate.url, provider: .claude)
            let bootstrap = ClaudeAgentSource.makeTailBootstrap(
                url: candidate.url,
                candidateSessionID: candidate.sessionId,
                storedCursor: storedCursor,
                storedAggregate: storedAggregate
            )
            readers[candidate.sessionId] = bootstrap.reader
            if let restoredModel = bootstrap.restoredModel {
                models[candidate.sessionId] = restoredModel
            } else if models[candidate.sessionId] == nil {
                models[candidate.sessionId] = ClaudeSessionModel(sessionId: candidate.sessionId)
                if storedAggregate != nil {
                    cursorStore?.removeAggregate(for: candidate.url)
                }
            }
            sourceURLs[candidate.sessionId] = candidate.url
        }

        for sessionId in Array(models.keys) where !discovered.contains(sessionId) {
            let lastEvent = models[sessionId]?.lastEventAt ?? .distantPast
            if now.timeIntervalSince(lastEvent) > Self.endedRetention {
                readers[sessionId] = nil
                models[sessionId] = nil
                sourceURLs[sessionId] = nil
            }
        }
    }

    private func composeSessions(now: Date, liveness: [String: Bool]) -> [MonitorAgentSessionState] {
        var states: [MonitorAgentSessionState] = []
        for (sessionId, model) in models {
            let alive = liveness[sessionId] ?? false
            var state = model.snapshot(now: now, processAlive: alive)
            // Overlay the cross-scan wait clock: stamp the flip into needsInput with
            // the session's last event time, carry it while blocked, clear otherwise.
            state.waitSince = waitTracker.waitSince(
                sessionID: state.id,
                status: state.status,
                eventTime: state.lastEventAt
            )
            if state.status == .ended,
               now.timeIntervalSince1970 - state.lastEventAt > Self.endedRetention {
                continue
            }
            states.append(state)
        }
        waitTracker.retainOnly(Set(states.map(\.id)))
        states.sort { $0.lastEventAt > $1.lastEventAt }
        return states
    }

    /// Roll the trailing-14-day per-model/per-day history + burn rates for the Claude root.
    func currentUsageLedger() -> MonitorUsageLedgerFragment {
        let now = Date()
        let buckets: [MonitorFileUsageBuckets]
        if backfill.shouldRefresh(now: now) {
            let refs = ledgerFileRefs(now: now)
            buckets = backfill.refresh(files: refs, now: now)
        } else {
            buckets = backfill.cachedBuckets()
        }

        let today = currentUsage()
        let todayTokens = today.tokensToday ?? .zero
        let cumulative = todayTokens.input + todayTokens.output + todayTokens.cacheRead + todayTokens.cacheWrite
        burnWindow.record(at: now.timeIntervalSince1970, cumulativeTokens: cumulative, cumulativeCost: today.costTodayUSD)
        let rates = burnWindow.rates()

        return MonitorUsageLedgerFragment(
            fileBuckets: buckets,
            tokensPerHour: rates.tokensPerHour,
            costPerHour: rates.costPerHour
        )
    }

    /// Transcript files whose mtime is inside the ledger day window. Reuses the
    /// scanner's discovery but with the 14-day lookback (not the 48h status one).
    private func ledgerFileRefs(now: Date) -> [MonitorUsageFileRef] {
        let lookback = TimeInterval(MonitorUsageRollup.dayWindow) * 24 * 3600
        guard let candidates = try? scanner.discoverTranscripts(now: now, lookback: lookback, limit: 400) else {
            return []
        }
        return candidates.map {
            MonitorUsageFileRef(url: $0.url, provider: .claude, size: $0.sizeBytes, mtime: $0.modifiedAt)
        }
    }

    func currentUsage() -> MonitorProviderUsage {
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        var tokens = MonitorTokenTotals.zero
        var cost = 0.0
        var sawCost = false

        for model in models.values {
            guard let last = model.lastEventAt, last.timeIntervalSince1970 >= startOfToday else { continue }
            tokens = tokens + model.tokens
            if let sessionCost = model.costUSD() {
                cost += sessionCost
                sawCost = true
            }
        }

        return MonitorProviderUsage(
            costTodayUSD: sawCost ? cost : nil,
            tokensToday: tokens == .zero ? nil : tokens
        )
    }

    // MARK: - Sink helpers

    private func pushAgents(_ sessions: [MonitorAgentSessionState]) async {
        await sink?.updateAgents(sourceID: sourceID, sessions: sessions)
    }

    private func pushHealth(state: String, detail: String?, now: Date) async {
        await sink?.updateHealth(MonitorSourceHealth(
            sourceID: sourceID,
            state: state,
            detail: detail,
            lastUpdateAt: now.timeIntervalSince1970
        ))
    }

    private var sourceID: String { "claude" }
}
