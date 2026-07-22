import Testing
import Foundation
import LiveWallpaperCore
@testable import LiveWallpaper

@Suite("Monitor runtime v2 plumbing")
struct MonitorRuntimeV2PlumbingTests {

    @Test("Each widget kind flips exactly its sampler gate")
    func kindMapsToItsGate() {
        #expect(MonitorRuntime.systemOptions(for: [.gpu]) == options(gpu: true, sensors: true))
        #expect(MonitorRuntime.systemOptions(for: [.cpu]) == options(topProcesses: true, sensors: true))
        #expect(MonitorRuntime.systemOptions(for: [.processes]) == options(topProcesses: true))
        #expect(MonitorRuntime.systemOptions(for: [.memory]) == options(topProcesses: true))
        #expect(MonitorRuntime.systemOptions(for: [.disk]) == options(processIO: true))
        #expect(MonitorRuntime.systemOptions(for: [.aiEngine]) == options(ane: true))
        #expect(MonitorRuntime.systemOptions(for: [.power]) == options(accessories: true, sensors: true))
    }

    @Test("A kind with no expensive sampler leaves every gate off")
    func inertKindKeepsAllGatesOff() {
        #expect(MonitorRuntime.systemOptions(for: [.network]) == SystemMetricsSource.Options(
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
        #expect(opts.topProcesses == true)
        #expect(opts.ane == false)
        #expect(opts.sensors == true)
    }

    @Test("Every kind placed turns every gate on")
    func allKindsAllGates() {
        let opts = MonitorRuntime.systemOptions(for: Set(MonitorWidgetKind.allCases))
        #expect(opts == SystemMetricsSource.Options(
            gpu: true, topProcesses: true, ane: true, accessories: true, sensors: true,
            processIO: true
        ))
    }

    @Test("The Disk widget demands the per-app I/O walk; others leave it off")
    func diskKindFlipsProcessIO() {
        #expect(MonitorRuntime.systemOptions(for: [.disk]).processIO == true)
        #expect(MonitorRuntime.systemOptions(for: [.cpu, .processes]).processIO == false)
    }

    @Test("activeWidgetKinds unions across leases")
    func kindsUnionAcrossLeases() {
        var a = MonitorRuntimeOptions(system: true)
        a.activeWidgetKinds = [.gpu, .cpu]
        var b = MonitorRuntimeOptions(system: true)
        b.activeWidgetKinds = [.power, .cpu]

        let merged = MonitorRuntime.merged([a, b])
        #expect(merged?.activeWidgetKinds == [.gpu, .cpu, .power])
        #expect(MonitorRuntime.systemOptions(for: merged?.activeWidgetKinds ?? []) == SystemMetricsSource.Options(
            gpu: true, topProcesses: true, ane: false, accessories: true, sensors: true
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
        let plain = MonitorRuntimeOptions(system: true)

        #expect(MonitorRuntime.merged([withKinds, plain])?.activeWidgetKinds == [.gpu])
        #expect(MonitorRuntime.merged([plain, withKinds])?.activeWidgetKinds == [.gpu])
    }

    @Test("v1 leases (no activeWidgetKinds) leave the union set nil")
    func v1LeasesLeaveUnionNil() {
        let systemOnly = MonitorRuntimeOptions(system: true, topProcesses: true)
        let quiet = MonitorRuntimeOptions(system: false)
        #expect(MonitorRuntime.merged([systemOnly, quiet])?.activeWidgetKinds == nil)
    }

    @Test("v1 default Options keeps GPU + accessories on, ANE off")
    func v1DefaultOptionsPreserved() {
        let defaults = SystemMetricsSource.Options.default
        #expect(defaults.gpu == true)
        #expect(defaults.accessories == true)
        #expect(defaults.ane == false)
        #expect(defaults.topProcesses == false)
    }

    @Test("Ledger fragments roll into perModel + dailyActivity on the published snapshot")
    func ledgerFragmentsPopulateRollup() async {
        let now = Date()
        let today = MonitorUsageRollup.dayKey(now.timeIntervalSince1970)

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

        #expect(snapshot.costTodayUSD == 2.0)
        #expect(snapshot.tokensToday == MonitorTokenTotals(input: 140, output: 60))
        #expect(snapshot.perProvider?.count == 2)

        let models = Set((snapshot.perModel ?? []).map(\.model))
        #expect(models == ["claude-opus-4", "claude-sonnet-5"])

        #expect(snapshot.dailyActivity?.count == MonitorUsageRollup.dayWindow)
        let todayBucket = snapshot.dailyActivity?.first { $0.day == today }
        #expect(todayBucket?.tokens == MonitorTokenTotals(input: 140, output: 60))

        #expect(snapshot.tokenBurnRatePerHour == 1500)
        #expect(snapshot.costBurnRatePerHour == 0.9)
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
            ledgerProviders: [],
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
            ledger: MonitorUsageLedgerFragment()
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
        #expect(snapshot.fiveHourUsedPercent == 0.42)
        #expect(snapshot.weekUsedPercent == 0.71)
        #expect(snapshot.limitsStale == true)
    }

    private func options(
        gpu: Bool = false, topProcesses: Bool = false, ane: Bool = false,
        accessories: Bool = false, sensors: Bool = false, processIO: Bool = false
    ) -> SystemMetricsSource.Options {
        SystemMetricsSource.Options(
            gpu: gpu, topProcesses: topProcesses, ane: ane, accessories: accessories,
            sensors: sensors, processIO: processIO
        )
    }

    private func buckets(day: String, model: String, input: Int, output: Int) -> MonitorFileUsageBuckets {
        var b = MonitorFileUsageBuckets()
        b.add(day: day, model: model, tokens: MonitorTokenTotals(input: input, output: output))
        return b
    }
}

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
