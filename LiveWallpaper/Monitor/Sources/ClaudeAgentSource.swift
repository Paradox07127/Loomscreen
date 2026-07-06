import Foundation

/// Monitor data source for Claude Code sessions.
///
/// Discovers `~/.claude/projects/*/*.jsonl` transcripts, tails each with a
/// `JSONLTailReader`, folds lines through a per-session `ClaudeSessionModel`,
/// and pushes normalized, privacy-redacted `MonitorAgentSessionState`s into the
/// hub sink. Process liveness comes from `ClaudeSessionScanner`.
///
/// The type is a `final class` (immutable stored state) whose mutable working
/// set lives entirely inside an internal `actor`, so it is `Sendable` and free
/// of data races without locks.
final class ClaudeAgentSource: MonitorDataSource {
    let sourceID = "claude"

    private let engine: Engine

    init(rootURL: URL, cursorStore: MonitorTailCursorStore? = nil) {
        self.engine = Engine(rootURL: rootURL, cursorStore: cursorStore)
    }

    func start(sink: any MonitorSnapshotSink) async {
        await engine.start(sink: sink)
    }

    func stop() async {
        await engine.stop()
    }

    /// Claude-only usage for today. The integrator composes this into the shared
    /// `MonitorUsageSnapshot`; this source deliberately never calls
    /// `sink.updateUsage`.
    func currentUsage() async -> MonitorProviderUsage {
        await engine.currentUsage()
    }
}

// MARK: - Engine (all mutable state, isolated)

private actor Engine {
    private let rootURL: URL
    private let scanner: ClaudeSessionScanner
    private let cursorStore: MonitorTailCursorStore?

    private var sink: (any MonitorSnapshotSink)?
    private var pollTask: Task<Void, Never>?

    // Per-session working set, keyed by sessionId.
    private var readers: [String: JSONLTailReader] = [:]
    private var models: [String: ClaudeSessionModel] = [:]
    private var sourceURLs: [String: URL] = [:]

    private var lastScan: Date = .distantPast
    private var consecutiveIOFailures = 0

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

    func stop() {
        pollTask?.cancel()
        pollTask = nil
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
                    // Keep the model for its final ended snapshot; drop the reader.
                    readers[sessionId] = nil
                    if let url = sourceURLs[sessionId] {
                        cursorStore?.remove(for: url)
                    }
                    continue
                }
                if outcome.didRotate {
                    // Byte stream restarted: rebuild the accumulator from scratch.
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
                    cursorStore?.set(cursorState, for: url)
                    if let model = models[sessionId] {
                        cursorStore?.setAggregate(model.snapshotState(), for: url)
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
            let restoredModel = storedCursor.flatMap { _ in
                storedAggregate.flatMap(ClaudeSessionModel.restore)
            }
            readers[candidate.sessionId] = JSONLTailReader(
                url: candidate.url,
                resumeFrom: restoredModel == nil ? nil : storedCursor
            )
            if let restoredModel {
                models[candidate.sessionId] = restoredModel
            } else if models[candidate.sessionId] == nil {
                models[candidate.sessionId] = ClaudeSessionModel(sessionId: candidate.sessionId)
                if storedAggregate != nil {
                    cursorStore?.removeAggregate(for: candidate.url)
                }
            }
            sourceURLs[candidate.sessionId] = candidate.url
        }

        // Forget sessions that aged out of the discovery window entirely, so the
        // working set doesn't grow without bound across a long-lived app.
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
            let state = model.snapshot(now: now, processAlive: alive)
            // Drop long-dead sessions from the surfaced list.
            if state.status == .ended,
               now.timeIntervalSince1970 - state.lastEventAt > Self.endedRetention {
                continue
            }
            states.append(state)
        }
        states.sort { $0.lastEventAt > $1.lastEventAt }
        return states
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
