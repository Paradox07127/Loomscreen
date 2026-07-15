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
    /// `nil` (v1 callers) leaves the system source on its default demand gates;
    /// a non-nil set drives `SystemMetricsSource.Options` so an expensive sampler
    /// (GPU / top processes / ANE / accessories) only runs when a matching widget
    /// is actually placed. Unioned across leases like every other option.
    var activeWidgetKinds: Set<MonitorWidgetKind>?
    /// GPU sampling period in seconds, from the GPU widget's `gpuSampleSeconds`
    /// option. nil ⇒ the default cadence (~6s). Merged across leases by MIN so
    /// the fastest request wins.
    var gpuSampleSeconds: Double?
}

/// Account-level usage-ledger fragment a source can optionally expose (per-model +
/// per-day history + burn rates). Mirrors `MonitorUsageProviding`: composed by
/// `MonitorRuntime` because no single source owns the cross-provider ledger.
/// `MonitorProviderUsage` has no slot for this history, so it rides a separate
/// seam that the runtime merges via `MonitorUsageRollup`.
protocol MonitorUsageLedgerProviding: Sendable {
    func currentUsageLedger() async -> MonitorUsageLedgerFragment
}

extension ClaudeAgentSource: MonitorUsageLedgerProviding {}
extension CodexAgentSource: MonitorUsageLedgerProviding {}

/// The security-scoped grant plumbing the runtime drives, behind a seam so the
/// suspend tests can prove a resume re-opens nothing — the property this type
/// exists to provide is invisible from the outside otherwise.
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

/// App-wide owner of the monitor data pipeline so N displays showing the Monitor
/// wallpaper share one hub + one set of sources.
///
/// Lifecycle is lease-based: each view acquires under a unique lease ID and later
/// releases that same ID. Because views issue both calls as fire-and-forget
/// tasks, a release can reach the actor before its matching acquire — that early
/// release is remembered and cancels the late acquire instead of leaving an
/// orphaned pipeline. Same-ID option changes go through `updateOptions` (never
/// `acquire`) so a refresh that races the lease's own teardown can't resurrect a
/// released lease. The pipeline always runs with the UNION of every live lease's
/// UNPAUSED options (so one system-only display can't strip agent modules from
/// another), and rebuilds are chained through a single task so overlapping
/// acquire/release/refresh calls never interleave mid-start.
///
/// `setPaused` is the energy seam: a wallpaper the performance policy suspended
/// pauses its lease rather than releasing it, so the samplers it alone demanded
/// are torn down while the lease slot survives for a cheap resume.
///
/// Agent/usage sources live in separate adapter files wired through
/// `extraSourceFactories` — registered once at startup — letting this coordinator
/// compile and run system-only without them. Security-scoped agent roots are
/// resolved HERE (never by views) so sandbox-scope lifetime is owned by the
/// pipeline's owner rather than by any one display. Scope lifetime tracks LIVE
/// LEASES, not the pipeline: every lease pausing tears the samplers down but
/// keeps the resolved roots open, which is what makes the resume cheap. The
/// scopes close when no live lease wants AI data any more.
actor MonitorRuntime {
    static let shared = MonitorRuntime()

    private let grants: MonitorGrantAccess

    init(grants: MonitorGrantAccess = .live) {
        self.grants = grants
    }

    typealias SourceFactory = @Sendable (MonitorRuntimeOptions) -> [any MonitorDataSource]

    /// Registered at app startup by whichever module owns the agent/usage adapters.
    /// Each factory returns the sources it can build for the given options (or `[]`).
    /// `@MainActor`-isolated because registration happens once during app launch;
    /// the actor hops to read it when (re)building the pipeline.
    @MainActor static var extraSourceFactories: [SourceFactory] = []

    nonisolated let broker = MonitorSnapshotBroker()

    /// One view's claim on the pipeline. A paused lease keeps its slot but
    /// contributes nothing to the merged options, so whatever it alone demanded is
    /// torn down; every lease paused ⇒ no pipeline at all.
    private struct Lease {
        var options: MonitorRuntimeOptions
        var isPaused = false
    }

    /// What is known about a lease ID with no live lease. Views issue acquire,
    /// setPaused and release as separate fire-and-forget tasks, so calls for one
    /// ID land in any order and this is the only state that bridges them.
    ///
    /// `pausedBeforeAcquire` and `retired` both describe "a pause arrived with no
    /// lease to apply it to" and MUST stay distinguishable: the first belongs to
    /// an acquire still in flight, the second to a lease that is already gone. A
    /// `retired` ID recorded as `pausedBeforeAcquire` would hand the stale pause
    /// to whatever acquires that ID next — and the HUD/overlay controllers reuse
    /// one process-constant ID across every show/hide.
    private enum DetachedLease {
        /// A release overtook its own acquire: cancel that acquire when it lands.
        case releasedBeforeAcquire
        /// A pause overtook its own acquire: apply it to that acquire.
        case pausedBeforeAcquire(Bool)
        /// The lease lived and was released. Terminal until the ID is acquired
        /// again, which starts a fresh lease that inherits nothing.
        case retired
    }

    private var hub: MonitorDataHub?
    private var sources: [any MonitorDataSource] = []
    private var usageTask: Task<Void, Never>?
    private var leases: [UUID: Lease] = [:]
    /// Out-of-order call state for IDs with no live lease. One small entry per
    /// lease ID that has been released and not re-acquired.
    private var detached: [UUID: DetachedLease] = [:]
    /// Union options the current pipeline was requested with (pre-resolution).
    private var activeOptions: MonitorRuntimeOptions?
    /// Roots resolved under the current grants, held open by live leases. Cached
    /// so a resume (or any rebuild that still wants AI data) reuses the open
    /// security scopes instead of re-resolving the bookmarks. Cleared exactly
    /// when the grants are released.
    private var resolvedRoots: (claude: URL?, codex: URL?)?
    private var rebuildTask: Task<Void, Never>?

    var debugActiveLeaseCount: Int { leases.count }
    var debugPausedLeaseCount: Int { leases.values.filter(\.isPaused).count }
    /// Options the live pipeline is actually running with. `nil` ⇒ no pipeline
    /// exists (no lease, or every lease paused) ⇒ nothing is being sampled.
    var debugActiveOptions: MonitorRuntimeOptions? { activeOptions }
    var debugActiveSourceCount: Int { sources.count }

    func acquire(leaseID: UUID, options: MonitorRuntimeOptions) async {
        switch detached.removeValue(forKey: leaseID) {
        case .releasedBeforeAcquire:
            return
        case .pausedBeforeAcquire(let paused):
            leases[leaseID] = Lease(options: options, isPaused: paused)
        case .retired, nil:
            leases[leaseID] = Lease(options: options, isPaused: leases[leaseID]?.isPaused ?? false)
        }
        await rebuild()
    }

    /// Pause/resume one lease's contribution without releasing it. A paused lease
    /// drops out of the merged options, so the sources only it demanded are
    /// stopped — this is what makes a suspended wallpaper actually stop sampling
    /// rather than just stop drawing.
    func setPaused(leaseID: UUID, paused: Bool) async {
        guard let lease = leases[leaseID] else {
            switch detached[leaseID] {
            case nil, .pausedBeforeAcquire:
                // Racing its own acquire: remember it so the late acquire applies it.
                detached[leaseID] = .pausedBeforeAcquire(paused)
            case .releasedBeforeAcquire, .retired:
                // The lease this addressed is gone; it dies with that lease
                // rather than waiting for the ID's next one.
                break
            }
            return
        }
        guard lease.isPaused != paused else { return }
        leases[leaseID]?.isPaused = paused
        await rebuild()
    }

    /// Refresh an already-live lease's options WITHOUT creating one. Callers use
    /// this (not `acquire`) for same-ID option changes so a refresh that races the
    /// lease's own teardown can't resurrect a released lease: if the `release`
    /// task wins, this update simply finds no lease and no-ops instead of
    /// recreating an orphaned pipeline no one owes a release for. A live-lease
    /// refresh (the common case) mutates in place and rebuilds as before.
    func updateOptions(leaseID: UUID, options: MonitorRuntimeOptions) async {
        guard leases[leaseID] != nil else { return }
        // Mutates only the options: a live-config refresh must not silently
        // un-pause a suspended wallpaper's lease.
        leases[leaseID]?.options = options
        await rebuild()
    }

    func release(leaseID: UUID) async {
        guard leases.removeValue(forKey: leaseID) != nil else {
            switch detached[leaseID] {
            case nil, .pausedBeforeAcquire:
                detached[leaseID] = .releasedBeforeAcquire
            case .releasedBeforeAcquire, .retired:
                // Already dead — a second release must not re-arm the cancel and
                // shoot down a legitimate future acquire on a reused ID.
                break
            }
            return
        }
        detached[leaseID] = .retired
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
            // Union the placed-widget sets: a kind demanded by ANY screen turns its
            // sampler on. Absent on every lease ⇒ stays nil ⇒ default demand gates.
            if let kinds = entry.activeWidgetKinds {
                merged.activeWidgetKinds = (merged.activeWidgetKinds ?? []).union(kinds)
            }
            // Fastest requested GPU sampling period wins across screens.
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
            // CPU (L "Top by CPU" list) and Memory (L "Top by memory" list) both
            // show a process attribution, so either — not just the Processes
            // widget — demands the top-process walk.
            gpu: kinds.contains(.gpu),
            topProcesses: kinds.contains(.processes) || kinds.contains(.cpu) || kinds.contains(.memory),
            ane: kinds.contains(.aiEngine),
            accessories: kinds.contains(.power),
            sensors: kinds.contains(.cpu) || kinds.contains(.gpu) || kinds.contains(.power),
            // The Disk widget's L "top by I/O" list rides the same walk.
            processIO: kinds.contains(.disk)
        )
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
        // Paused leases are excluded: with every lease paused this yields nil and
        // the pipeline stops outright.
        let target = Self.merged(leases.values.filter { !$0.isPaused }.map(\.options))
        let rebuilding = force || target != activeOptions
        if rebuilding { await stopPipeline() }
        // Grants answer to live leases (paused ones included), not to the
        // pipeline. Reconciled even when the pipeline itself is unchanged: the
        // last lease can go away while every lease was already paused, and
        // `target` stays nil across that, so the no-op guard would skip it.
        let stillWanted = leases.values.contains { $0.options.agents || $0.options.usage }
        if force || !stillWanted { await releaseGrants() }
        guard rebuilding else { return }
        broker.clear()
        activeOptions = target
        guard let target else { return }

        let hub = MonitorDataHub(broker: broker)
        await hub.setModuleEnabled(agents: target.agents, usage: target.usage)
        self.hub = hub

        var resolved = target
        if target.agents || target.usage {
            let roots: (claude: URL?, codex: URL?)
            if let cached = resolvedRoots {
                roots = cached
            } else {
                roots = await grants.resolveRoots()
                // Only a resolution that opened a scope is worth holding: an
                // unresolved grant keeps being retried, so a grant the user makes
                // later is picked up without waiting for `refreshSources`.
                if roots.claude != nil || roots.codex != nil { resolvedRoots = roots }
            }
            resolved.claudeRoot = resolved.claudeRoot ?? roots.claude
            resolved.codexRoot = resolved.codexRoot ?? roots.codex
            // Why-no-data: when an AI module is wanted but a root can't resolve
            // (no grant / stale bookmark), say so — both in the log and as a
            // synthesized health record the widgets' empty states can read.
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
        }

        var built: [any MonitorDataSource] = []
        if resolved.system {
            if let kinds = resolved.activeWidgetKinds {
                // Demand-gated: only build the samplers the placed widgets need.
                built.append(SystemMetricsSource(
                    options: Self.systemOptions(for: kinds),
                    gpuSampleCadence: Self.gpuCadence(forSeconds: resolved.gpuSampleSeconds) ?? 3
                ))
            } else {
                // v1 path: default demand gates (GPU + accessories on, ANE off),
                // top processes driven by the legacy module toggle.
                built.append(SystemMetricsSource(includeTopProcesses: resolved.topProcesses))
            }
        }
        let factories = await MainActor.run { Self.extraSourceFactories }
        for factory in factories {
            built.append(contentsOf: factory(resolved))
        }

        sources = built
        for source in built {
            await source.start(sink: hub)
        }
        monitorSourcesLog.info("🛰️ pipeline: agents=\(resolved.agents) usage=\(resolved.usage) claudeRoot=\(resolved.claudeRoot != nil) codexRoot=\(resolved.codexRoot != nil) sources=\(built.map(\.sourceID).joined(separator: ","), privacy: .public)")

        if resolved.usage {
            let providers: [(id: String, provider: any MonitorUsageProviding)] = built.compactMap { source in
                guard let provider = source as? any MonitorUsageProviding else { return nil }
                return (source.sourceID, provider)
            }
            // Ledger providers contribute per-model/per-day history + burn rates via
            // a separate seam; merged here so the published snapshot carries the full
            // ledger alongside today/quota. Same source instances, cheap cached reads.
            let ledgerProviders: [any MonitorUsageLedgerProviding] = built.compactMap { $0 as? any MonitorUsageLedgerProviding }
            // Account rate limits ride in on the Claude Code statusline payload
            // teed into the (read-only) claude root by the user's capture script;
            // nil when no root is granted or the user hasn't installed it.
            let limitsReader: ClaudeRateLimitReader? = resolved.claudeRoot.map { ClaudeRateLimitReader(rootURL: $0) }
            if providers.isEmpty && limitsReader == nil {
                monitorSourcesLog.warning("🛰️ usage task skipped: no providers, no limits reader")
            }
            if !providers.isEmpty || limitsReader != nil {
                usageTask = Task { [hub] in
                    while !Task.isCancelled {
                        // Re-read limits each tick so the freshness window advances.
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

    /// Compose one published usage snapshot from the live providers: today/quota
    /// from `MonitorUsageProviding`, per-model/per-day history + burn rates from the
    /// `MonitorUsageLedgerProviding` fragments (pooled buckets rolled through
    /// `MonitorUsageRollup`, per-provider burn rates summed nil-aware), and account
    /// limits from the already-read `ClaudeRateLimits`. Pure aside from awaiting the
    /// providers' cached reads — the test drives it with synthetic providers.
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

        // Merge every provider's ledger fragment: pool file buckets for the
        // perModel/dailyActivity rollup, sum the already-windowed per-provider burn
        // rates (nil-aware, so nil+nil stays nil).
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
        for source in sources {
            await source.stop()
        }
        sources.removeAll()
        hub = nil
    }

    /// Closes the security scopes and drops the cached roots together — the cache
    /// is only valid while the scopes it was resolved under are still open.
    private func releaseGrants() async {
        resolvedRoots = nil
        await grants.release()
    }
}
