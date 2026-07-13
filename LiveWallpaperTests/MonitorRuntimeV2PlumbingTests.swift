import Testing
import Foundation
import LiveWallpaperCore
@testable import LiveWallpaper

/// Wave-1+2 integration seams inside `MonitorRuntime`: the usage-ledger merge
/// (`MonitorUsageLedgerProviding` fragments → published `MonitorUsageSnapshot`)
/// and demand-gated sampling (`activeWidgetKinds` union → `SystemMetricsSource
/// .Options`). Uses the runtime's nonisolated static seams so no real pipeline,
/// timers, or file I/O spin up — mirroring `MonitorRuntimeTests`.
@Suite("Monitor runtime v2 plumbing")
struct MonitorRuntimeV2PlumbingTests {

    // MARK: - Demand-gated sampling: kinds → Options

    @Test("Each widget kind flips exactly its sampler gate")
    func kindMapsToItsGate() {
        // cpu/gpu/health/power all light the SMC sensor read (each shows a
        // temperature readout); .gpu/.power also flip their own gated walk.
        #expect(MonitorRuntime.systemOptions(for: [.gpu]) == options(gpu: true, sensors: true))
        #expect(MonitorRuntime.systemOptions(for: [.cpu]) == options(sensors: true))
        #expect(MonitorRuntime.systemOptions(for: [.health]) == options(sensors: true))
        #expect(MonitorRuntime.systemOptions(for: [.processes]) == options(topProcesses: true))
        #expect(MonitorRuntime.systemOptions(for: [.aiEngine]) == options(ane: true))
        #expect(MonitorRuntime.systemOptions(for: [.power]) == options(accessories: true, sensors: true))
    }

    @Test("A kind with no expensive sampler leaves every gate off")
    func inertKindKeepsAllGatesOff() {
        // clock/memory need no gated walk → all flags stay false (cpu/gpu differ:
        // they light the SMC sensor gate), unlike the pre-v2 default which leaves
        // GPU + accessories on.
        #expect(MonitorRuntime.systemOptions(for: [.clock]) == SystemMetricsSource.Options(
            gpu: false, topProcesses: false, ane: false, accessories: false
        ))
    }

    @Test("Empty kind set gates every expensive sampler off")
    func emptyKindsGateAllOff() {
        let opts = MonitorRuntime.systemOptions(for: [])
        #expect(opts.gpu == false)
        #expect(opts.topProcesses == false)
        #expect(opts.ane == false)
        #expect(opts.accessories == false)
        #expect(opts.sensors == false)
    }

    @Test("Multiple placed kinds union into their combined gates")
    func multipleKindsUnionGates() {
        let opts = MonitorRuntime.systemOptions(for: [.gpu, .power, .cpu])
        #expect(opts.gpu == true)
        #expect(opts.accessories == true)
        #expect(opts.topProcesses == false)   // no .processes widget
        #expect(opts.ane == false)             // no .aiEngine widget
        #expect(opts.sensors == true)          // cpu + gpu both want the SMC row
    }

    @Test("Every kind placed turns every gate on")
    func allKindsAllGates() {
        let opts = MonitorRuntime.systemOptions(for: Set(MonitorWidgetKind.allCases))
        #expect(opts == SystemMetricsSource.Options(
            gpu: true, topProcesses: true, ane: true, accessories: true, sensors: true
        ))
    }

    // MARK: - Demand-gated sampling: multi-lease union of activeWidgetKinds

    @Test("activeWidgetKinds unions across leases")
    func kindsUnionAcrossLeases() {
        var a = MonitorRuntimeOptions(system: true)
        a.activeWidgetKinds = [.gpu, .cpu]
        var b = MonitorRuntimeOptions(system: true)
        b.activeWidgetKinds = [.power, .cpu]

        let merged = MonitorRuntime.merged([a, b])
        #expect(merged?.activeWidgetKinds == [.gpu, .cpu, .power])
        // …and that union drives the combined gates.
        #expect(MonitorRuntime.systemOptions(for: merged?.activeWidgetKinds ?? []) == SystemMetricsSource.Options(
            gpu: true, topProcesses: false, ane: false, accessories: true, sensors: true
        ))
    }

    @Test("A single lease with kinds carries its set through the union unchanged")
    func singleLeaseKindsPreserved() {
        var lease = MonitorRuntimeOptions(system: true)
        lease.activeWidgetKinds = [.aiEngine]
        #expect(MonitorRuntime.merged([lease])?.activeWidgetKinds == [.aiEngine])
    }

    @Test("A lease that omits kinds doesn't erase another lease's set")
    func absentKindsDoesNotClearUnion() {
        var withKinds = MonitorRuntimeOptions(system: true)
        withKinds.activeWidgetKinds = [.gpu]
        let plain = MonitorRuntimeOptions(system: true)   // activeWidgetKinds nil

        #expect(MonitorRuntime.merged([withKinds, plain])?.activeWidgetKinds == [.gpu])
        #expect(MonitorRuntime.merged([plain, withKinds])?.activeWidgetKinds == [.gpu])
    }

    // MARK: - v1 path: no kinds preserves defaults

    @Test("v1 leases (no activeWidgetKinds) leave the union set nil")
    func v1LeasesLeaveUnionNil() {
        // The default MonitorRuntimeOptions used across v1 call sites never sets
        // activeWidgetKinds, so the merged pipeline stays on the includeTopProcesses
        // branch (default demand gates) rather than the demand-gated one.
        let systemOnly = MonitorRuntimeOptions(system: true, topProcesses: true)
        let quiet = MonitorRuntimeOptions(system: false)
        #expect(MonitorRuntime.merged([systemOnly, quiet])?.activeWidgetKinds == nil)
    }

    @Test("v1 default Options keeps GPU + accessories on, ANE off")
    func v1DefaultOptionsPreserved() {
        // The branch v1 callers hit (SystemMetricsSource(includeTopProcesses:))
        // must preserve the pre-v2 gate profile.
        let defaults = SystemMetricsSource.Options.default
        #expect(defaults.gpu == true)
        #expect(defaults.accessories == true)
        #expect(defaults.ane == false)
        #expect(defaults.topProcesses == false)
    }

    // MARK: - Usage-ledger merge into published snapshot

    @Test("Ledger fragments roll into perModel + dailyActivity on the published snapshot")
    func ledgerFragmentsPopulateRollup() async {
        let now = Date()
        let today = MonitorUsageRollup.dayKey(now.timeIntervalSince1970)

        // Two providers, each contributing today's usage + a ledger fragment.
        let claude = SyntheticUsageSource(
            id: "claude",
            usage: MonitorProviderUsage(costTodayUSD: 2.0, tokensToday: MonitorTokenTotals(input: 100, output: 50)),
            ledger: MonitorUsageLedgerFragment(
                fileBuckets: [buckets(day: today, model: "claude-opus-4", input: 100, output: 50)],
                tokensPerHour: 1200,
                costPerHour: 0.9
            )
        )
        let codex = SyntheticUsageSource(
            id: "codex",
            usage: MonitorProviderUsage(costTodayUSD: nil, tokensToday: MonitorTokenTotals(input: 40, output: 10)),
            ledger: MonitorUsageLedgerFragment(
                fileBuckets: [buckets(day: today, model: "claude-sonnet-5", input: 40, output: 10)],
                tokensPerHour: 300,
                costPerHour: nil
            )
        )

        let snapshot = await MonitorRuntime.composeUsageSnapshot(
            providers: [(id: "claude", provider: claude), (id: "codex", provider: codex)],
            ledgerProviders: [claude, codex],
            limits: nil,
            now: now
        )

        // Today/quota still composed from the usage seam.
        #expect(snapshot.costTodayUSD == 2.0)
        #expect(snapshot.tokensToday == MonitorTokenTotals(input: 140, output: 60))
        #expect(snapshot.perProvider?.count == 2)

        // perModel carries both models from the merged buckets.
        let models = Set((snapshot.perModel ?? []).map(\.model))
        #expect(models == ["claude-opus-4", "claude-sonnet-5"])

        // dailyActivity spans the rollup window and today carries the pooled totals.
        #expect(snapshot.dailyActivity?.count == MonitorUsageRollup.dayWindow)
        let todayBucket = snapshot.dailyActivity?.first { $0.day == today }
        #expect(todayBucket?.tokens == MonitorTokenTotals(input: 140, output: 60))

        // Burn rates sum nil-aware across providers.
        #expect(snapshot.tokenBurnRatePerHour == 1500)     // 1200 + 300
        #expect(snapshot.costBurnRatePerHour == 0.9)        // 0.9 + nil
    }

    @Test("No ledger providers ⇒ ledger fields stay nil, today/quota still compose")
    func noLedgerProvidersLeavesLedgerNil() async {
        let usageOnly = SyntheticUsageSource(
            id: "claude",
            usage: MonitorProviderUsage(costTodayUSD: 1.0, tokensToday: MonitorTokenTotals(input: 10)),
            ledger: MonitorUsageLedgerFragment()
        )
        let snapshot = await MonitorRuntime.composeUsageSnapshot(
            providers: [(id: "claude", provider: usageOnly)],
            ledgerProviders: [],                    // no ledger seam wired
            limits: nil,
            now: Date()
        )
        #expect(snapshot.costTodayUSD == 1.0)
        #expect(snapshot.tokensToday == MonitorTokenTotals(input: 10))
        #expect(snapshot.perModel == nil)
        #expect(snapshot.dailyActivity == nil)
        #expect(snapshot.tokenBurnRatePerHour == nil)
        #expect(snapshot.costBurnRatePerHour == nil)
    }

    @Test("Empty ledger fragments produce no perModel/dailyActivity")
    func emptyLedgerFragmentsStayNil() async {
        let source = SyntheticUsageSource(
            id: "claude",
            usage: MonitorProviderUsage(costTodayUSD: nil, tokensToday: nil),
            ledger: MonitorUsageLedgerFragment()   // empty buckets, nil rates
        )
        let snapshot = await MonitorRuntime.composeUsageSnapshot(
            providers: [(id: "claude", provider: source)],
            ledgerProviders: [source],
            limits: nil,
            now: Date()
        )
        #expect(snapshot.perModel == nil)
        #expect(snapshot.dailyActivity == nil)
        #expect(snapshot.tokenBurnRatePerHour == nil)
        #expect(snapshot.costBurnRatePerHour == nil)
        #expect(snapshot.tokensToday == nil)
    }

    @Test("Account limits land on the snapshot normalized to 0…1 fractions")
    func limitsPassThrough() async {
        let source = SyntheticUsageSource(
            id: "claude",
            usage: MonitorProviderUsage(costTodayUSD: 1.0, tokensToday: MonitorTokenTotals(input: 5)),
            ledger: MonitorUsageLedgerFragment()
        )
        var limits = ClaudeRateLimits()
        limits.fiveHourUsedPercent = 42
        limits.weekUsedPercent = 71
        limits.isStale = true

        let snapshot = await MonitorRuntime.composeUsageSnapshot(
            providers: [(id: "claude", provider: source)],
            ledgerProviders: [source],
            limits: limits,
            now: Date()
        )
        // Reader carries raw 0…100 percentages; the snapshot contract is 0…1.
        #expect(snapshot.fiveHourUsedPercent == 0.42)
        #expect(snapshot.weekUsedPercent == 0.71)
        #expect(snapshot.limitsStale == true)
    }

    // MARK: - Helpers

    private func options(
        gpu: Bool = false, topProcesses: Bool = false, ane: Bool = false,
        accessories: Bool = false, sensors: Bool = false
    ) -> SystemMetricsSource.Options {
        SystemMetricsSource.Options(
            gpu: gpu, topProcesses: topProcesses, ane: ane, accessories: accessories, sensors: sensors
        )
    }

    private func buckets(day: String, model: String, input: Int, output: Int) -> MonitorFileUsageBuckets {
        var b = MonitorFileUsageBuckets()
        b.add(day: day, model: model, tokens: MonitorTokenTotals(input: input, output: output))
        return b
    }
}

/// Immutable synthetic source that satisfies both usage seams from fixed values,
/// so the composer can be exercised without a real file-tailing pipeline.
private final class SyntheticUsageSource: MonitorUsageProviding, MonitorUsageLedgerProviding {
    private let usageValue: MonitorProviderUsage
    private let ledgerValue: MonitorUsageLedgerFragment
    let id: String

    init(id: String, usage: MonitorProviderUsage, ledger: MonitorUsageLedgerFragment) {
        self.id = id
        self.usageValue = usage
        self.ledgerValue = ledger
    }

    func currentUsage() async -> MonitorProviderUsage { usageValue }
    func currentUsageLedger() async -> MonitorUsageLedgerFragment { ledgerValue }
}
