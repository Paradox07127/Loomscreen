import Foundation

struct MonitorRuntimeOptions: Sendable, Equatable {
    var system = true
    var agents = false
    var usage = false
    var topProcesses = false
    var claudeRoot: URL?
    var codexRoot: URL?
}

/// App-wide owner of the monitor data pipeline so N displays showing the Monitor
/// wallpaper share one hub + one set of sources.
///
/// Lifecycle is lease-based: each view acquires under a unique lease ID and later
/// releases that same ID. Because views issue both calls as fire-and-forget
/// tasks, a release can reach the actor before its matching acquire — that early
/// release is remembered and cancels the late acquire instead of leaving an
/// orphaned pipeline. The pipeline always runs with the UNION of every live
/// lease's options (so one system-only display can't strip agent modules from
/// another), and rebuilds are chained through a single task so overlapping
/// acquire/release/refresh calls never interleave mid-start.
///
/// Agent/usage sources live in separate adapter files wired through
/// `extraSourceFactories` — registered once at startup — letting this coordinator
/// compile and run system-only without them. Security-scoped agent roots are
/// resolved HERE (never by views) so sandbox-scope lifetime exactly matches
/// pipeline lifetime.
actor MonitorRuntime {
    static let shared = MonitorRuntime()

    typealias SourceFactory = @Sendable (MonitorRuntimeOptions) -> [any MonitorDataSource]

    /// Registered at app startup by whichever module owns the agent/usage adapters.
    /// Each factory returns the sources it can build for the given options (or `[]`).
    /// `@MainActor`-isolated because registration happens once during app launch;
    /// the actor hops to read it when (re)building the pipeline.
    @MainActor static var extraSourceFactories: [SourceFactory] = []

    nonisolated let broker = MonitorSnapshotBroker()

    private var hub: MonitorDataHub?
    private var sources: [any MonitorDataSource] = []
    private var usageTask: Task<Void, Never>?
    private var leases: [UUID: MonitorRuntimeOptions] = [:]
    /// Releases that arrived before their matching acquire.
    private var orphanedReleases: Set<UUID> = []
    /// Union options the current pipeline was requested with (pre-resolution).
    private var activeOptions: MonitorRuntimeOptions?
    private var rebuildTask: Task<Void, Never>?

    var debugActiveLeaseCount: Int { leases.count }

    func acquire(leaseID: UUID, options: MonitorRuntimeOptions) async {
        if orphanedReleases.remove(leaseID) != nil { return }
        leases[leaseID] = options
        await rebuild()
    }

    func release(leaseID: UUID) async {
        guard leases.removeValue(forKey: leaseID) != nil else {
            orphanedReleases.insert(leaseID)
            return
        }
        await rebuild()
    }

    /// Re-resolves grants and rebuilds under the current leases — call after the
    /// user authorizes a data root so live sources pick it up immediately.
    func refreshSources() async {
        await rebuild(force: true)
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
        }
        return merged
    }

    private func rebuild(force: Bool = false) async {
        let previous = rebuildTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.performRebuild(force: force)
        }
        rebuildTask = task
        await task.value
    }

    private func performRebuild(force: Bool) async {
        // Recomputed at execution time so the last rebuild in a chained burst
        // settles on the final lease state and earlier ones collapse to no-ops.
        let target = Self.merged(Array(leases.values))
        guard force || target != activeOptions else { return }

        await stopPipeline()
        broker.clear()
        activeOptions = target
        guard let target else { return }

        let hub = MonitorDataHub(broker: broker)
        await hub.setModuleEnabled(agents: target.agents, usage: target.usage)
        self.hub = hub

        var resolved = target
        if target.agents {
            let roots = await MainActor.run {
                (MonitorSourceAuthorization.shared.resolveClaudeRoot(),
                 MonitorSourceAuthorization.shared.resolveCodexRoot())
            }
            resolved.claudeRoot = resolved.claudeRoot ?? roots.0
            resolved.codexRoot = resolved.codexRoot ?? roots.1
        }

        var built: [any MonitorDataSource] = []
        if resolved.system {
            built.append(SystemMetricsSource(includeTopProcesses: resolved.topProcesses))
        }
        let factories = await MainActor.run { Self.extraSourceFactories }
        for factory in factories {
            built.append(contentsOf: factory(resolved))
        }

        sources = built
        for source in built {
            await source.start(sink: hub)
        }

        if resolved.usage {
            let providers: [(id: String, provider: any MonitorUsageProviding)] = built.compactMap { source in
                guard let provider = source as? any MonitorUsageProviding else { return nil }
                return (source.sourceID, provider)
            }
            // Account rate limits ride in on the Claude Code statusline payload
            // teed into the (read-only) claude root by the user's capture script;
            // nil when no root is granted or the user hasn't installed it.
            let limitsReader: ClaudeRateLimitReader? = resolved.claudeRoot.map { ClaudeRateLimitReader(rootURL: $0) }
            if !providers.isEmpty || limitsReader != nil {
                usageTask = Task { [hub] in
                    while !Task.isCancelled {
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
                        if Task.isCancelled { return }
                        var snapshot = MonitorUsageSnapshot()
                        snapshot.perProvider = perProvider.isEmpty ? nil : perProvider
                        snapshot.costTodayUSD = totalCost
                        snapshot.tokensToday = sawTokens ? totalTokens : nil
                        if let limits = limitsReader?.currentLimits() {
                            snapshot.limitsStale = limits.isStale ? true : nil
                            snapshot.fiveHourUsedPercent = limits.fiveHourUsedPercent
                            snapshot.fiveHourResetsAt = limits.fiveHourResetsAt
                            snapshot.weekUsedPercent = limits.weekUsedPercent
                            snapshot.weekResetsAt = limits.weekResetsAt
                        }
                        await hub.updateUsage(snapshot)
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
            }
        }
    }

    private func stopPipeline() async {
        // Await the composer so a cancelled-but-running iteration can't publish
        // stale usage into the broker after `clear()`.
        if let task = usageTask {
            usageTask = nil
            task.cancel()
            await task.value
        }
        for source in sources {
            await source.stop()
        }
        sources.removeAll()
        hub = nil
        // Scope lifetime matches pipeline lifetime; a rebuild that still wants
        // agents re-resolves (and re-opens) the grants right after this.
        await MainActor.run { MonitorSourceAuthorization.shared.release() }
    }
}
