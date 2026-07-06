import Foundation
import os

final class CodexAgentSource: MonitorDataSource {
    let sourceID = "codex"

    private static let activePollInterval: TimeInterval = 1.5
    private static let idlePollInterval: TimeInterval = 5
    private static let rescanInterval: TimeInterval = 10
    private static let endedRetention: TimeInterval = 2 * 60 * 60

    /// Lifecycle state touched by `start`/`stop`. Lock-guarded so the type is
    /// `Sendable` without relying on the caller serializing start/stop — matching
    /// how the sibling `ClaudeAgentSource` confines the same state in an actor.
    private struct Lifecycle {
        var pollTask: Task<Void, Never>?
        var didStartSecurityScope = false
    }

    private let rootURL: URL
    private let cursorStore: MonitorTailCursorStore?
    private let usageLock = OSAllocatedUnfairLock(initialState: MonitorProviderUsage(costTodayUSD: nil, tokensToday: .zero))
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
                        cursorStore?.set(cursorState, for: file.url)
                        if let model = models[file.url] {
                            cursorStore?.setAggregate(model.snapshotState(), for: file.url)
                        }
                    }
                } catch {
                    pollHadError = true
                }
            }

            let sessions = Self.sessionStates(modelsByURL: models, files: files, now: now)
            setCurrentUsage(Self.usageSnapshot(from: Array(models.values), now: now))
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

    static func sessionStates(
        modelsByURL: [URL: CodexSessionModel],
        files: [CodexSessionScanner.SessionFile],
        now: Date
    ) -> [MonitorAgentSessionState] {
        files.compactMap { file in
            guard let model = modelsByURL[file.url],
                  let state = model.sessionState(
                    now: now,
                    processAlive: file.processAlive,
                    fallbackSessionId: fallbackSessionId(for: file.url),
                    fallbackProjectName: "Codex"
                  ) else {
                return nil
            }

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
