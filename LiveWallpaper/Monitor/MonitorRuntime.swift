import Foundation
import LiveWallpaperCore
import os

/// 🛰️-prefixed why-no-data diagnostics for the AI source pipeline; isolate
/// on-device with `log stream --predicate 'eventMessage CONTAINS "🛰️"'`.
let monitorSourcesLog = os.Logger(subsystem: "com.livewallpaper", category: "MonitorSources")

struct MonitorRuntimeOptions: Sendable, Equatable {
    var system = true
    var agents = false
    var usage = false
    var topProcesses = false
    var claudeRoot: URL?
    var codexRoot: URL?
    /// Widget kinds placed on the board across all screens sharing this lease.
    var activeWidgetKinds: Set<MonitorWidgetKind>?
    /// GPU sampling period in seconds, from the GPU widget's `gpuSampleSeconds` option.
    var gpuSampleSeconds: Double?
}

/// Account-level usage-ledger fragment a source can optionally expose (per-model + per-day history + burn rates).
protocol MonitorUsageLedgerProviding: Sendable {
    func currentUsageLedger() async -> MonitorUsageLedgerFragment
}

extension ClaudeAgentSource: MonitorUsageLedgerProviding {}
extension CodexAgentSource: MonitorUsageLedgerProviding {}

/// The security-scoped grant plumbing the runtime drives, behind a seam so the suspend tests can prove a resume re-opens nothing — the property this type exists to provide is invisible from the outside otherwise.
struct MonitorGrantAccess: Sendable {
    var resolveRoots: @Sendable () async -> (claude: URL?, codex: URL?)
    var release: @Sendable () async -> Void

    static let live = MonitorGrantAccess(
        resolveRoots: {
            await MainActor.run {
                (MonitorSourceAuthorization.shared.resolveClaudeRoot(),
                 MonitorSourceAuthorization.shared.resolveCodexRoot())
            }
        },
        release: {
            await MainActor.run { MonitorSourceAuthorization.shared.release() }
        }
    )
}

/// A caller-owned command stream for one logical runtime lease slot.
final class MonitorRuntimeLeaseSlot: Sendable {
    private struct State: Sendable {
        var nextSequence: UInt64 = 0
        var currentGeneration: UInt64?
        var desiredState: MonitorRuntimeLeaseDesiredState?
        var pendingEvent: MonitorRuntimeLeaseEvent?
        var drainTask: Task<Void, Never>?
        var drainLaunchCount: UInt64 = 0
    }

    private static let generationCounter = OSAllocatedUnfairLock(initialState: UInt64(0))
    private static let completedTask = Task<Void, Never> {}

    private let runtime: MonitorRuntime
    fileprivate let leaseID = UUID()
    private let state = OSAllocatedUnfairLock(initialState: State())

    fileprivate init(runtime: MonitorRuntime) {
        self.runtime = runtime
    }

    /// Starts a new generation in this slot and queues its acquire before
    /// returning. The returned handle is the only authority for later events.
    func acquire(options: MonitorRuntimeOptions) -> MonitorRuntimeLeaseHandle {
        let generation = Self.generationCounter.withLock { value -> UInt64 in
            value &+= 1
            precondition(value != 0, "Monitor runtime lease generation exhausted")
            return value
        }
        let handle = MonitorRuntimeLeaseHandle(slot: self, generation: generation)
        handle.enqueue(.acquire(options))
        return handle
    }

    fileprivate func enqueue(
        generation: UInt64,
        command: MonitorRuntimeLeaseCommand
    ) -> Task<Void, Never> {
        state.withLock { state in
            state.nextSequence &+= 1
            precondition(state.nextSequence != 0, "Monitor runtime lease sequence exhausted")
            let sequence = state.nextSequence

            switch command {
            case let .acquire(options):
                // Generation allocation happens before this lock.
                if let current = state.currentGeneration, generation <= current {
                    return state.drainTask ?? Self.completedTask
                }
                state.currentGeneration = generation
                state.desiredState = .active(options: options, isPaused: false)

            case let .updateOptions(options):
                guard state.currentGeneration == generation,
                      case let .active(_, isPaused) = state.desiredState else {
                    return state.drainTask ?? Self.completedTask
                }
                state.desiredState = .active(options: options, isPaused: isPaused)

            case let .setPaused(isPaused):
                guard state.currentGeneration == generation,
                      case let .active(options, _) = state.desiredState else {
                    return state.drainTask ?? Self.completedTask
                }
                state.desiredState = .active(options: options, isPaused: isPaused)

            case .release:
                guard state.currentGeneration == generation,
                      case .active = state.desiredState else {
                    return state.drainTask ?? Self.completedTask
                }
                state.desiredState = .released
            }

            guard let desiredState = state.desiredState else {
                return state.drainTask ?? Self.completedTask
            }

            state.pendingEvent = MonitorRuntimeLeaseEvent(
                leaseID: leaseID,
                generation: generation,
                sequence: sequence,
                desiredState: desiredState
            )
            if let task = state.drainTask { return task }

            state.drainLaunchCount &+= 1
            let task = Task.detached { [self] in
                await drain()
            }
            state.drainTask = task
            return task
        }
    }

    private func drain() async {
        while true {
            let event = state.withLock { state -> MonitorRuntimeLeaseEvent? in
                guard let event = state.pendingEvent else {
                    // Clearing under the same lock that enqueue uses closes the lost-wakeup race: the next command either belongs to this worker or creates exactly one replacement.
                    state.drainTask = nil
                    return nil
                }
                state.pendingEvent = nil
                return event
            }
            guard let event else { return }
            await runtime.apply(event)
        }
    }

    var debugPendingCommandCount: Int {
        state.withLock { $0.pendingEvent == nil ? 0 : 1 }
    }

    var debugDrainWorkerCount: Int {
        state.withLock { $0.drainTask == nil ? 0 : 1 }
    }

    var debugDrainLaunchCount: UInt64 {
        state.withLock { $0.drainLaunchCount }
    }

    fileprivate var settledTask: Task<Void, Never> { Self.completedTask }
}

/// Generation-scoped authority returned by `MonitorRuntimeLeaseSlot.acquire`.
final class MonitorRuntimeLeaseHandle: Sendable {
    private struct State: Sendable {
        var isReleased = false
        var tail: Task<Void, Never>?
    }

    private let slot: MonitorRuntimeLeaseSlot
    let generation: UInt64
    private let state = OSAllocatedUnfairLock(initialState: State())

    fileprivate init(slot: MonitorRuntimeLeaseSlot, generation: UInt64) {
        self.slot = slot
        self.generation = generation
    }

    var leaseID: UUID { slot.leaseID }

    @discardableResult
    func updateOptions(_ options: MonitorRuntimeOptions) -> Task<Void, Never> {
        enqueue(.updateOptions(options))
    }

    @discardableResult
    func setPaused(_ paused: Bool) -> Task<Void, Never> {
        enqueue(.setPaused(paused))
    }

    @discardableResult
    func release() -> Task<Void, Never> {
        state.withLock { state in
            guard !state.isReleased else {
                return state.tail ?? slot.settledTask
            }
            state.isReleased = true
            let task = slot.enqueue(generation: generation, command: .release)
            state.tail = task
            return task
        }
    }

    func waitUntilSettled() async {
        let tail = state.withLock { $0.tail }
        await tail?.value
    }

    @discardableResult
    fileprivate func enqueue(_ command: MonitorRuntimeLeaseCommand) -> Task<Void, Never> {
        state.withLock { state in
            guard !state.isReleased else {
                return state.tail ?? slot.settledTask
            }
            let task = slot.enqueue(generation: generation, command: command)
            state.tail = task
            return task
        }
    }
}

private enum MonitorRuntimeLeaseCommand: Sendable {
    case acquire(MonitorRuntimeOptions)
    case updateOptions(MonitorRuntimeOptions)
    case setPaused(Bool)
    case release
}

private enum MonitorRuntimeLeaseDesiredState: Sendable {
    case active(options: MonitorRuntimeOptions, isPaused: Bool)
    case released
}

private struct MonitorRuntimeLeaseEvent: Sendable {
    let leaseID: UUID
    let generation: UInt64
    let sequence: UInt64
    let desiredState: MonitorRuntimeLeaseDesiredState
}

/// App-wide owner of the monitor data pipeline so N displays showing the Monitor wallpaper share one hub + one set of sources.
actor MonitorRuntime {
    static let shared = MonitorRuntime()

    private let grants: MonitorGrantAccess
    /// Tests can supply a source seam without mutating the process-global MainActor registry.
    private let sourceFactoriesOverride: [SourceFactory]?

    init(
        grants: MonitorGrantAccess = .live,
        sourceFactories: [SourceFactory]? = nil
    ) {
        self.grants = grants
        self.sourceFactoriesOverride = sourceFactories
    }

    typealias SourceFactory = @Sendable (MonitorRuntimeOptions) -> [any MonitorDataSource]

    /// Registered at app startup by whichever module owns the agent/usage adapters.
    @MainActor static var extraSourceFactories: [SourceFactory] = []

    nonisolated let broker = MonitorSnapshotBroker()

    /// One view's claim on the pipeline.
    private struct Lease {
        var generation: UInt64
        var lastSequence: UInt64
        var options: MonitorRuntimeOptions
        var isPaused = false
    }

    private var hub: MonitorDataHub?
    private var sources: [any MonitorDataSource] = []
    private var usageTask: Task<Void, Never>?
    private var leases: [UUID: Lease] = [:]
    /// Union options the current pipeline was requested with (pre-resolution).
    private var activeOptions: MonitorRuntimeOptions?
    /// Roots resolved under the current grants, held open by live leases.
    private var resolvedRoots: (claude: URL?, codex: URL?)?
    private var rebuildTask: Task<Void, Never>?
    private var rebuildRevision: UInt64 = 0
    private var forceRebuildRequested = false
    private var rebuildWorkerLaunchCount: UInt64 = 0
    /// Termination is a one-way lifecycle for the app-wide runtime.
    private enum Lifecycle: Equatable {
        case running
        case shuttingDown
        case terminated
    }
    private var lifecycle: Lifecycle = .running
    /// Shared by every concurrent shutdown caller.
    private var shutdownTask: Task<Void, Never>?

    var debugActiveLeaseCount: Int { leases.count }
    var debugPausedLeaseCount: Int { leases.values.filter(\.isPaused).count }
    /// Options the live pipeline is actually running with. `nil` ⇒ no pipeline
    /// exists (no lease, or every lease paused) ⇒ nothing is being sampled.
    var debugActiveOptions: MonitorRuntimeOptions? { activeOptions }
    var debugActiveSourceCount: Int { sources.count }
    var debugIsTerminated: Bool { lifecycle == .terminated }
    /// Total actor-side lease bookkeeping. It is intentionally identical to the
    /// live lease count: completed generations leave no retired-ID state behind.
    var debugLeaseBookkeepingCount: Int { leases.count }
    var debugRebuildWorkerCount: Int { rebuildTask == nil ? 0 : 1 }
    var debugRebuildWorkerLaunchCount: UInt64 { rebuildWorkerLaunchCount }
    var debugRebuildRevision: UInt64 { rebuildRevision }

    nonisolated func makeLeaseSlot() -> MonitorRuntimeLeaseSlot {
        MonitorRuntimeLeaseSlot(runtime: self)
    }

    fileprivate func apply(_ event: MonitorRuntimeLeaseEvent) async {
        guard lifecycle == .running else { return }

        switch event.desiredState {
        case let .active(options, isPaused):
            if let current = leases[event.leaseID] {
                guard event.generation > current.generation
                    || (event.generation == current.generation && event.sequence > current.lastSequence)
                else { return }
            }
            leases[event.leaseID] = Lease(
                generation: event.generation,
                lastSequence: event.sequence,
                options: options,
                isPaused: isPaused
            )

        case .released:
            guard let current = leases[event.leaseID] else { return }
            // A release for a newer generation also retires an actor-side older generation when acquire+release coalesced before the drain reached the actor.
            guard event.generation > current.generation
                || (event.generation == current.generation && event.sequence > current.lastSequence)
            else { return }
            leases.removeValue(forKey: event.leaseID)
        }
        await rebuild()
    }

    /// Re-resolves grants and rebuilds under the current leases — call after the
    /// user authorizes a data root so live sources pick it up immediately.
    func refreshSources() async {
        guard lifecycle == .running else { return }
        await rebuild(force: true)
    }

    /// Stops the complete producer graph and closes every lease/grant before returning.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        lifecycle = .shuttingDown
        leases.removeAll()

        let admittedRebuilds = rebuildTask
        let task = Task { [weak self] in
            await admittedRebuilds?.value
            await self?.finishShutdown()
        }
        shutdownTask = task
        await task.value
    }

    /// Union across leases: any lease wanting a module turns it on.
    static func merged(_ options: [MonitorRuntimeOptions]) -> MonitorRuntimeOptions? {
        guard !options.isEmpty else { return nil }
        var merged = MonitorRuntimeOptions(system: false)
        for entry in options {
            merged.system = merged.system || entry.system
            merged.agents = merged.agents || entry.agents
            merged.usage = merged.usage || entry.usage
            merged.topProcesses = merged.topProcesses || entry.topProcesses
            if merged.claudeRoot == nil { merged.claudeRoot = entry.claudeRoot }
            if merged.codexRoot == nil { merged.codexRoot = entry.codexRoot }
            if let kinds = entry.activeWidgetKinds {
                merged.activeWidgetKinds = (merged.activeWidgetKinds ?? []).union(kinds)
            }
            if let seconds = entry.gpuSampleSeconds {
                merged.gpuSampleSeconds = min(merged.gpuSampleSeconds ?? seconds, seconds)
            }
        }
        return merged
    }

    /// GPU cadence (in 2s base ticks) for a requested sampling period; nil keeps
    /// the source's default (~6s).
    static func gpuCadence(forSeconds seconds: Double?) -> Int? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return max(1, Int((seconds / 2.0).rounded()))
    }

    /// Map the union of placed widget kinds to the system source's per-concern
    /// demand gates. Each expensive walk runs only when its widget is on the board.
    static func systemOptions(for kinds: Set<MonitorWidgetKind>) -> SystemMetricsSource.Options {
        SystemMetricsSource.Options(
            gpu: kinds.contains(.gpu),
            topProcesses: kinds.contains(.processes) || kinds.contains(.cpu) || kinds.contains(.memory),
            ane: kinds.contains(.aiEngine),
            accessories: kinds.contains(.power),
            sensors: kinds.contains(.cpu) || kinds.contains(.gpu) || kinds.contains(.power),
            processIO: kinds.contains(.disk)
        )
    }

    private func rebuild(force: Bool = false) async {
        guard lifecycle == .running else { return }
        rebuildRevision &+= 1
        precondition(rebuildRevision != 0, "Monitor runtime rebuild revision exhausted")
        forceRebuildRequested = forceRebuildRequested || force

        if let rebuildTask {
            await rebuildTask.value
            return
        }

        rebuildWorkerLaunchCount &+= 1
        let task = Task { [weak self] in
            guard let self else { return }
            await runRebuildLoop()
        }
        rebuildTask = task
        await task.value
    }

    /// One actor-owned rebuild worker folds every mutation that arrives while a source start/stop is suspended.
    private func runRebuildLoop() async {
        while lifecycle == .running {
            let revision = rebuildRevision
            let force = forceRebuildRequested
            forceRebuildRequested = false
            await performRebuild(force: force)

            guard lifecycle == .running else { break }
            if revision == rebuildRevision {
                rebuildTask = nil
                return
            }
        }
        rebuildTask = nil
    }

    private func performRebuild(force: Bool) async {
        guard lifecycle == .running else { return }
        let target = Self.merged(leases.values.filter { !$0.isPaused }.map(\.options))
        let rebuilding = force || target != activeOptions
        if rebuilding {
            await stopPipeline()
            // `stopPipeline()` is an actor-reentrancy point.
            guard lifecycle == .running else { return }
        }
        let stillWanted = leases.values.contains { $0.options.agents || $0.options.usage }
        if force || !stillWanted {
            await releaseGrants()
            guard lifecycle == .running else { return }
        }
        guard rebuilding else { return }
        broker.clear()
        activeOptions = target
        guard let target else { return }

        let hub = MonitorDataHub(broker: broker)
        await hub.setModuleEnabled(agents: target.agents, usage: target.usage)
        guard lifecycle == .running else { return }
        self.hub = hub

        var resolved = target
        if target.agents || target.usage {
            let roots: (claude: URL?, codex: URL?)
            if let cached = resolvedRoots {
                roots = cached
            } else {
                roots = await grants.resolveRoots()
                guard lifecycle == .running else { return }
                if roots.claude != nil || roots.codex != nil { resolvedRoots = roots }
            }
            resolved.claudeRoot = resolved.claudeRoot ?? roots.claude
            resolved.codexRoot = resolved.codexRoot ?? roots.codex
            // Why-no-data: when an AI module is wanted but a root can't resolve (no grant / stale bookmark), say so — both in the log and as a synthesized health record the widgets' empty states can read.
            if resolved.claudeRoot == nil {
                monitorSourcesLog.warning("🛰️ claude root unresolved (no grant?) — agent/usage sources disabled")
                await hub.updateHealth(MonitorSourceHealth(
                    sourceID: "claude", state: "unauthorized",
                    detail: "folder not granted", lastUpdateAt: Date().timeIntervalSince1970
                ))
            }
            if resolved.codexRoot == nil {
                monitorSourcesLog.warning("🛰️ codex root unresolved (no grant?) — agent/usage sources disabled")
                await hub.updateHealth(MonitorSourceHealth(
                    sourceID: "codex", state: "unauthorized",
                    detail: "folder not granted", lastUpdateAt: Date().timeIntervalSince1970
                ))
            }
            guard lifecycle == .running else { return }
        }

        var built: [any MonitorDataSource] = []
        if resolved.system {
            if let kinds = resolved.activeWidgetKinds {
                built.append(SystemMetricsSource(
                    options: Self.systemOptions(for: kinds),
                    gpuSampleCadence: Self.gpuCadence(forSeconds: resolved.gpuSampleSeconds) ?? 3
                ))
            } else {
                built.append(SystemMetricsSource(includeTopProcesses: resolved.topProcesses))
            }
        }
        let factories: [SourceFactory]
        if let sourceFactoriesOverride {
            factories = sourceFactoriesOverride
        } else {
            factories = await MainActor.run { Self.extraSourceFactories }
            guard lifecycle == .running else { return }
        }
        for factory in factories {
            built.append(contentsOf: factory(resolved))
        }

        sources = built
        for source in built {
            await source.start(sink: hub)
            // A source start is also reentrant.
            guard lifecycle == .running else { return }
        }
        monitorSourcesLog.info("🛰️ pipeline: agents=\(resolved.agents) usage=\(resolved.usage) claudeRoot=\(resolved.claudeRoot != nil) codexRoot=\(resolved.codexRoot != nil) sources=\(built.map(\.sourceID).joined(separator: ","), privacy: .public)")

        if resolved.usage {
            let providers: [(id: String, provider: any MonitorUsageProviding)] = built.compactMap { source in
                guard let provider = source as? any MonitorUsageProviding else { return nil }
                return (source.sourceID, provider)
            }
            let ledgerProviders: [any MonitorUsageLedgerProviding] = built.compactMap { $0 as? any MonitorUsageLedgerProviding }
            let limitsReader: ClaudeRateLimitReader? = resolved.claudeRoot.map { ClaudeRateLimitReader(rootURL: $0) }
            if providers.isEmpty && limitsReader == nil {
                monitorSourcesLog.warning("🛰️ usage task skipped: no providers, no limits reader")
            }
            if !providers.isEmpty || limitsReader != nil {
                usageTask = Task { [hub] in
                    while !Task.isCancelled {
                        let snapshot = await Self.composeUsageSnapshot(
                            providers: providers,
                            ledgerProviders: ledgerProviders,
                            limits: limitsReader?.currentLimits(),
                            now: Date()
                        )
                        if Task.isCancelled { return }
                        await hub.updateUsage(snapshot)
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
            }
        }
    }

    /// Composes a usage snapshot from live provider totals and ledger history.
    static func composeUsageSnapshot(
        providers: [(id: String, provider: any MonitorUsageProviding)],
        ledgerProviders: [any MonitorUsageLedgerProviding],
        limits: ClaudeRateLimits?,
        now: Date
    ) async -> MonitorUsageSnapshot {
        var perProvider: [String: MonitorProviderUsage] = [:]
        var totalCost: Double?
        var totalTokens = MonitorTokenTotals.zero
        var sawTokens = false
        for entry in providers {
            let usage = await entry.provider.currentUsage()
            perProvider[entry.id] = usage
            if let cost = usage.costTodayUSD { totalCost = (totalCost ?? 0) + cost }
            if let tokens = usage.tokensToday {
                totalTokens = totalTokens + tokens
                sawTokens = true
            }
        }

        var ledgerBuckets: [MonitorFileUsageBuckets] = []
        var tokenBurn: Double?
        var costBurn: Double?
        for provider in ledgerProviders {
            let fragment = await provider.currentUsageLedger()
            ledgerBuckets.append(contentsOf: fragment.fileBuckets)
            if let rate = fragment.tokensPerHour { tokenBurn = (tokenBurn ?? 0) + rate }
            if let rate = fragment.costPerHour { costBurn = (costBurn ?? 0) + rate }
        }

        var snapshot = MonitorUsageSnapshot()
        snapshot.perProvider = perProvider.isEmpty ? nil : perProvider
        snapshot.costTodayUSD = totalCost
        snapshot.tokensToday = sawTokens ? totalTokens : nil
        let rollup = MonitorUsageRollup.compose(files: ledgerBuckets, now: now.timeIntervalSince1970)
        snapshot.perModel = rollup.perModel
        snapshot.dailyActivity = rollup.dailyActivity
        snapshot.tokenBurnRatePerHour = tokenBurn
        snapshot.costBurnRatePerHour = costBurn
        if let limits {
            snapshot.limitsStale = limits.isStale ? true : nil
            // Reader carries the payload's raw 0…100 `used_percentage`; the
            // snapshot contract (ArcGauge/QuotaMeter) is a 0…1 fraction.
            snapshot.fiveHourUsedPercent = limits.fiveHourUsedPercent.map { min(max($0 / 100, 0), 1) }
            snapshot.fiveHourResetsAt = limits.fiveHourResetsAt
            snapshot.weekUsedPercent = limits.weekUsedPercent.map { min(max($0 / 100, 0), 1) }
            snapshot.weekResetsAt = limits.weekResetsAt
        }
        return snapshot
    }

    private func stopPipeline() async {
        // Await the composer so a cancelled-but-running iteration can't publish
        // stale usage into the broker after `clear()`.
        if let task = usageTask {
            usageTask = nil
            task.cancel()
            await task.value
        }
        // Detach ownership before awaiting so a re-entrant lifecycle call sees the truthful target state.
        let stoppingSources = sources
        sources.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for source in stoppingSources {
                group.addTask { await source.stop() }
            }
        }
        hub = nil
    }

    private func finishShutdown() async {
        await stopPipeline()
        activeOptions = nil
        broker.clear()
        await releaseGrants()
        rebuildTask = nil
        lifecycle = .terminated
    }

    /// Closes the security scopes and drops the cached roots together — the cache
    /// is only valid while the scopes it was resolved under are still open.
    private func releaseGrants() async {
        resolvedRoots = nil
        await grants.release()
    }
}
