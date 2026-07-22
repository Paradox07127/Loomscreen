import Testing
import Foundation
@testable import LiveWallpaper

struct MonitorUsageWidgetTests {

    @Test("burn ETA needs ≥2 samples")
    func burnEtaInsufficientSamples() {
        #expect(MonitorUsagePresentationPolicy.burnETASeconds(times: [], used: []) == nil)
        #expect(MonitorUsagePresentationPolicy.burnETASeconds(times: [100], used: [0.5]) == nil)
    }

    @Test("burn ETA from a positive two-point slope reaches 1.0")
    func burnEtaTwoPoint() {
        let eta = MonitorUsagePresentationPolicy.burnETASeconds(times: [0, 600], used: [0.50, 0.60])
        #expect(eta != nil)
        #expect(abs((eta ?? 0) - 2400) < 1.0)
    }

    @Test("burn ETA uses least-squares slope across many samples")
    func burnEtaLeastSquares() {
        let times = (0..<6).map { Double($0) * 60 }
        let used = (0..<6).map { 0.50 + Double($0) * 0.01 }
        let eta = MonitorUsagePresentationPolicy.burnETASeconds(times: times, used: used)
        #expect(eta != nil)
        #expect(abs((eta ?? 0) - 2700) < 5.0)
    }

    @Test("flat or falling series yields no ETA")
    func burnEtaNonPositiveSlope() {
        #expect(MonitorUsagePresentationPolicy.burnETASeconds(times: [0, 600], used: [0.6, 0.6]) == nil)
        #expect(MonitorUsagePresentationPolicy.burnETASeconds(times: [0, 600], used: [0.7, 0.4]) == nil)
    }

    @Test("already at the cap yields a zero ETA, not nil")
    func burnEtaAtCap() {
        let eta = MonitorUsagePresentationPolicy.burnETASeconds(times: [0, 600], used: [0.98, 1.0])
        #expect(eta == 0)
    }

    @Test("ETA is clamped so a whisper-slow slope doesn't overflow the horizon")
    func burnEtaClamped() {
        let eta = MonitorUsagePresentationPolicy.burnETASeconds(times: [0, 600], used: [0.50, 0.50001])
        #expect(eta == MonitorUsagePresentationPolicy.burnETAClampSeconds)
    }

    @Test("zero / negative dt between samples is ignored (no divide-by-zero)")
    func burnEtaGuardsBadTime() {
        #expect(MonitorUsagePresentationPolicy.burnETASeconds(times: [600, 600], used: [0.4, 0.6]) == nil)
    }

    @Test("near-limit dot band: warm ≥40%, crit >85%")
    func quotaBandThresholds() {
        #expect(MonitorUsagePresentationPolicy.quotaBand(0.10) == .normal)
        #expect(MonitorUsagePresentationPolicy.quotaBand(0.40) == .warm)
        #expect(MonitorUsagePresentationPolicy.quotaBand(0.85) == .warm)
        #expect(MonitorUsagePresentationPolicy.quotaBand(0.851) == .crit)
        #expect(MonitorUsagePresentationPolicy.quotaBand(0.91) == .crit)
    }

    @Test("bar-fill escalation: warn >75%, crit >90%")
    func quotaFillThresholds() {
        #expect(MonitorUsagePresentationPolicy.quotaFill(0.50) == .normal)
        #expect(MonitorUsagePresentationPolicy.quotaFill(0.75) == .normal)
        #expect(MonitorUsagePresentationPolicy.quotaFill(0.76) == .warn)
        #expect(MonitorUsagePresentationPolicy.quotaFill(0.90) == .warn)
        #expect(MonitorUsagePresentationPolicy.quotaFill(0.91) == .crit)
    }

    @Test("ETA critical flag flips at ≤15 min")
    func etaCriticalFlag() {
        #expect(MonitorUsagePresentationPolicy.isETACritical(15 * 60) == true)
        #expect(MonitorUsagePresentationPolicy.isETACritical(7 * 60) == true)
        #expect(MonitorUsagePresentationPolicy.isETACritical(38 * 60) == false)
    }

    @Test("cache segments are proportions of the four token totals")
    func cacheSegments() {
        var t = MonitorTokenTotals()
        t.input = 1_180_000
        t.output = 960_000
        t.cacheRead = 5_210_000
        t.cacheWrite = 1_070_000
        let segs = MonitorUsageWidgetView.cacheSegments(t)
        #expect(segs.count == 4)
        let total = 1_180_000.0 + 960_000 + 5_210_000 + 1_070_000
        #expect(abs(segs[0].fraction - 1_180_000 / total) < 1e-9)
        #expect(abs(segs[2].fraction - 5_210_000 / total) < 1e-9)
        #expect(abs(segs.reduce(0) { $0 + $1.fraction } - 1.0) < 1e-9)
    }

    @Test("empty cache totals give zero fractions, never NaN")
    func cacheSegmentsEmpty() {
        let segs = MonitorUsageWidgetView.cacheSegments(.zero)
        #expect(segs.allSatisfy { $0.fraction == 0 && $0.fraction.isFinite })
    }

    @Test("cache hit rate = cacheRead / (input + cacheRead)")
    func cacheHitRate() {
        var t = MonitorTokenTotals()
        t.input = 1_180_000
        t.cacheRead = 5_210_000
        let hit = MonitorUsagePresentationPolicy.cacheHitRate(t)
        #expect(hit != nil)
        #expect(abs((hit ?? 0) - 5_210_000 / (1_180_000 + 5_210_000)) < 1e-9)
        #expect(MonitorUsagePresentationPolicy.cacheHitRate(.zero) == nil)
    }

    @Test("5h reset uses short countdown, week reset uses days-aware countdown")
    func resetFormatting() {
        #expect(MonitorUsagePresentationPolicy.fiveHourResetText(secondsRemaining: 2 * 3600 + 14 * 60) == "2h 14m")
        #expect(MonitorUsagePresentationPolicy.weekResetText(secondsRemaining: 3 * 86400 + 5 * 3600) == "3d 5h")
    }

    @Test("stale dimming keyed on limitsStale == true only")
    func staleDimming() {
        #expect(MonitorUsagePresentationPolicy.isLimitsStale(makeUsage(stale: true)) == true)
        #expect(MonitorUsagePresentationPolicy.isLimitsStale(makeUsage(stale: false)) == false)
        #expect(MonitorUsagePresentationPolicy.isLimitsStale(makeUsage(stale: nil)) == false)
    }

    @Test("quota blocks present only when the 5h fields exist")
    func quotaPresence() {
        #expect(MonitorUsagePresentationPolicy.hasQuota(makeUsage(five: 0.58)) == true)
        #expect(MonitorUsagePresentationPolicy.hasQuota(makeUsage(five: nil)) == false)
    }

    @Test("model family is prefix-matched, unknown ids fall through to .other")
    func modelFamilyClassification() {
        #expect(MonitorUsagePresentationPolicy.modelFamily("claude-opus-4-20250514") == .opus)
        #expect(MonitorUsagePresentationPolicy.modelFamily("claude-sonnet-5") == .sonnet)
        #expect(MonitorUsagePresentationPolicy.modelFamily("claude-3-5-haiku") == .haiku)
        #expect(MonitorUsagePresentationPolicy.modelFamily("gpt-5-mini") == .gpt5mini)
        #expect(MonitorUsagePresentationPolicy.modelFamily("gpt-5") == .gpt5)
        #expect(MonitorUsagePresentationPolicy.modelFamily("some-local-model") == .other)
    }

    @Test("gpt-5-mini classifies before gpt-5 (order matters)")
    func modelFamilyMiniPrecedence() {
        #expect(MonitorUsagePresentationPolicy.modelFamily("gpt-5-mini") == .gpt5mini)
        #expect(MonitorUsagePresentationPolicy.modelFamily("gpt-5") == .gpt5)
    }

    @Test("known families collapse to friendly labels; unknown ids drop a build stamp")
    func modelShortName() {
        #expect(MonitorUsagePresentationPolicy.modelShortName("claude-opus-4-20250514") == "Opus")
        #expect(MonitorUsagePresentationPolicy.modelShortName("claude-sonnet-5") == "Sonnet")
        #expect(MonitorUsagePresentationPolicy.modelShortName("gpt-5-mini") == "GPT-5 mini")
        #expect(MonitorUsagePresentationPolicy.modelShortName("my-model-20240101") == "my-model")
    }

    @Test("model tokens sums the four buckets")
    func modelTokens() {
        let m = MonitorUsageModelBreakdown(
            model: "claude-opus-4",
            tokens: MonitorTokenTotals(input: 100, output: 200, cacheRead: 300, cacheWrite: 400),
            costUSD: 1.0)
        #expect(MonitorUsagePresentationPolicy.modelTokens(m) == 1000)
    }

    @Test("topModels returns the busiest few, nil when absent")
    func topModels() {
        var u = MonitorUsageSnapshot()
        #expect(MonitorUsagePresentationPolicy.topModels(u) == nil)
        u.perModel = (0..<6).map { i in
            MonitorUsageModelBreakdown(model: "m\(i)",
                                       tokens: MonitorTokenTotals(input: 1000 - i * 100), costUSD: nil)
        }
        let top = MonitorUsagePresentationPolicy.topModels(u, limit: 4)
        #expect(top?.count == 4)
        #expect(top?.first?.model == "m0")
    }

    @Test("hasCache keys on non-zero today totals")
    func hasCache() {
        var u = MonitorUsageSnapshot()
        #expect(MonitorUsagePresentationPolicy.hasCache(u) == false)
        u.tokensToday = .zero
        #expect(MonitorUsagePresentationPolicy.hasCache(u) == false)
        u.tokensToday = MonitorTokenTotals(input: 5)
        #expect(MonitorUsagePresentationPolicy.hasCache(u) == true)
    }

    @Test("resolvedProvider defaults to \"all\", accepts claude/codex, rejects garbage")
    func resolvedProviderDefaults() {
        #expect(MonitorUsagePresentationPolicy.resolvedProvider(nil) == "all")
        #expect(MonitorUsagePresentationPolicy.resolvedProvider("") == "all")
        #expect(MonitorUsagePresentationPolicy.resolvedProvider("bogus") == "all")
        #expect(MonitorUsagePresentationPolicy.resolvedProvider("all") == "all")
        #expect(MonitorUsagePresentationPolicy.resolvedProvider("claude") == "claude")
        #expect(MonitorUsagePresentationPolicy.resolvedProvider("codex") == "codex")
    }

    @Test("resolvedPrimaryMetric defaults to \"tokens\", accepts cost, rejects garbage")
    func resolvedPrimaryMetricDefaults() {
        #expect(MonitorUsagePresentationPolicy.resolvedPrimaryMetric(nil) == "tokens")
        #expect(MonitorUsagePresentationPolicy.resolvedPrimaryMetric("") == "tokens")
        #expect(MonitorUsagePresentationPolicy.resolvedPrimaryMetric("bogus") == "tokens")
        #expect(MonitorUsagePresentationPolicy.resolvedPrimaryMetric("tokens") == "tokens")
        #expect(MonitorUsagePresentationPolicy.resolvedPrimaryMetric("cost") == "cost")
    }

    @Test("costLeads is true only for the explicit cost metric")
    func costLeadsFlag() {
        #expect(MonitorUsagePresentationPolicy.costLeads("cost") == true)
        #expect(MonitorUsagePresentationPolicy.costLeads("tokens") == false)
    }

    @Test("quota is Claude-only data: hidden under codex, visible under all/claude")
    func quotaVisibleByProvider() {
        #expect(MonitorUsagePresentationPolicy.quotaVisible("all") == true)
        #expect(MonitorUsagePresentationPolicy.quotaVisible("claude") == true)
        #expect(MonitorUsagePresentationPolicy.quotaVisible("codex") == false)
    }

    @Test("cross-provider aggregates (burn rate, trend, split bar) show only under all")
    func aggregatesVisibleByProvider() {
        #expect(MonitorUsagePresentationPolicy.aggregatesVisible("all") == true)
        #expect(MonitorUsagePresentationPolicy.aggregatesVisible("claude") == false)
        #expect(MonitorUsagePresentationPolicy.aggregatesVisible("codex") == false)
    }

    @Test("filteredCostTodayUSD: all is unfiltered, claude/codex read perProvider")
    func filteredCostTodayUSDByProvider() {
        let u = makeProviderSplitUsage()
        #expect(MonitorUsagePresentationPolicy.filteredCostTodayUSD(u, provider: "all") == 12.4)
        #expect(MonitorUsagePresentationPolicy.filteredCostTodayUSD(u, provider: "claude") == 8.1)
        #expect(MonitorUsagePresentationPolicy.filteredCostTodayUSD(u, provider: "codex") == nil)
    }

    @Test("filteredCostTodayUSD is nil when perProvider is absent entirely")
    func filteredCostTodayUSDNoPerProvider() {
        var u = MonitorUsageSnapshot()
        u.costTodayUSD = 5
        #expect(MonitorUsagePresentationPolicy.filteredCostTodayUSD(u, provider: "all") == 5)
        #expect(MonitorUsagePresentationPolicy.filteredCostTodayUSD(u, provider: "claude") == nil)
    }

    @Test("filteredTokensToday: all is unfiltered, claude/codex read perProvider")
    func filteredTokensTodayByProvider() {
        let u = makeProviderSplitUsage()
        #expect(MonitorUsagePresentationPolicy.filteredTokensToday(u, provider: "all")?.input == 5_700_000)
        #expect(MonitorUsagePresentationPolicy.filteredTokensToday(u, provider: "claude")?.input == 3_800_000)
        #expect(MonitorUsagePresentationPolicy.filteredTokensToday(u, provider: "codex")?.input == 1_900_000)
    }

    @Test("modelProvider: claude- prefix is Claude, everything else (gpt-5*, fallback \"codex\") is Codex")
    func modelProviderInference() {
        #expect(MonitorUsagePresentationPolicy.modelProvider("claude-opus-4-20250514") == "claude")
        #expect(MonitorUsagePresentationPolicy.modelProvider("claude-sonnet-5") == "claude")
        #expect(MonitorUsagePresentationPolicy.modelProvider("gpt-5") == "codex")
        #expect(MonitorUsagePresentationPolicy.modelProvider("gpt-5-mini") == "codex")
        #expect(MonitorUsagePresentationPolicy.modelProvider("codex") == "codex")
    }

    @Test("filteredPerModel: all is unfiltered, claude/codex drop the other provider's models")
    func filteredPerModelByProvider() {
        let u = makePerModelUsage()
        #expect(MonitorUsagePresentationPolicy.filteredPerModel(u, provider: "all")?.count == 3)
        let claudeOnly = MonitorUsagePresentationPolicy.filteredPerModel(u, provider: "claude")
        #expect(claudeOnly?.count == 2)
        #expect(claudeOnly?.allSatisfy { $0.model.hasPrefix("claude") } == true)
        let codexOnly = MonitorUsagePresentationPolicy.filteredPerModel(u, provider: "codex")
        #expect(codexOnly?.count == 1)
        #expect(codexOnly?.first?.model == "gpt-5")
    }

    @Test("filteredPerModel is nil (not empty array) when nothing matches the filter")
    func filteredPerModelEmptyMatchIsNil() {
        var u = MonitorUsageSnapshot()
        u.perModel = [MonitorUsageModelBreakdown(model: "claude-sonnet-5", tokens: MonitorTokenTotals(input: 10), costUSD: 0.01)]
        #expect(MonitorUsagePresentationPolicy.filteredPerModel(u, provider: "codex") == nil)
    }

    @Test("topModels(provider:) filters before applying the limit")
    func topModelsByProvider() {
        let u = makePerModelUsage()
        let claudeTop = MonitorUsagePresentationPolicy.topModels(u, limit: 4, provider: "claude")
        #expect(claudeTop?.count == 2)
        #expect(MonitorUsagePresentationPolicy.topModels(u, provider: "codex")?.first?.model == "gpt-5")
        #expect(MonitorUsagePresentationPolicy.topModels(u, limit: 4)?.count == 3)
    }

    @Test("hasCache(provider:) matches the provider-scoped tokens, not the raw total")
    func hasCacheByProvider() {
        let u = makeProviderSplitUsage()
        #expect(MonitorUsagePresentationPolicy.hasCache(u, provider: "all") == true)
        #expect(MonitorUsagePresentationPolicy.hasCache(u, provider: "claude") == true)
        var noCodex = u
        noCodex.perProvider?["codex"] = nil
        #expect(MonitorUsagePresentationPolicy.hasCache(noCodex, provider: "codex") == false)
    }

    private func makeUsage(
        five: Double? = 0.58, stale: Bool? = false
    ) -> MonitorUsageSnapshot {
        var u = MonitorUsageSnapshot()
        u.fiveHourUsedPercent = five
        u.fiveHourResetsAt = five == nil ? nil : 1000
        u.limitsStale = stale
        return u
    }

    private func makeProviderSplitUsage() -> MonitorUsageSnapshot {
        var u = MonitorUsageSnapshot()
        u.costTodayUSD = 12.4
        u.tokensToday = MonitorTokenTotals(input: 5_700_000, output: 2_720_000)
        u.perProvider = [
            "claude": MonitorProviderUsage(costTodayUSD: 8.1, tokensToday: MonitorTokenTotals(input: 3_800_000, output: 1_880_000)),
            "codex": MonitorProviderUsage(costTodayUSD: nil, tokensToday: MonitorTokenTotals(input: 1_900_000, output: 840_000))
        ]
        return u
    }

    private func makePerModelUsage() -> MonitorUsageSnapshot {
        var u = MonitorUsageSnapshot()
        u.perModel = [
            MonitorUsageModelBreakdown(model: "claude-opus-4-20250514", tokens: MonitorTokenTotals(input: 3_000_000), costUSD: 8.1),
            MonitorUsageModelBreakdown(model: "gpt-5", tokens: MonitorTokenTotals(input: 1_400_000), costUSD: nil),
            MonitorUsageModelBreakdown(model: "claude-sonnet-5", tokens: MonitorTokenTotals(input: 900_000), costUSD: 1.2)
        ]
        return u
    }
}
