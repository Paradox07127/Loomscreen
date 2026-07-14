import Testing
import Foundation
@testable import LiveWallpaper

/// Pure-logic tests for the Usage widget's data derivations — the burn-ETA slope
/// math over the sparse 5h-used% series, the two quota-escalation thresholds
/// (near-limit dot vs bar fill), the cache four-segment fractions, and the
/// stale-dimming rule. No UI: every case exercises the `nonisolated static`
/// helpers on `MonitorUsageWidgetView` directly, pinning the ported behaviour
/// from `index.html` `buildUsageSection` (`quotaBand`/`quotaFill`/burn ETA).
struct MonitorUsageWidgetTests {

    // MARK: - Burn ETA slope (client-derived "time to 5h cap")

    @Test("burn ETA needs ≥2 samples")
    func burnEtaInsufficientSamples() {
        #expect(MonitorUsageWidgetView.burnETASeconds(times: [], used: []) == nil)
        #expect(MonitorUsageWidgetView.burnETASeconds(times: [100], used: [0.5]) == nil)
    }

    @Test("burn ETA from a positive two-point slope reaches 1.0")
    func burnEtaTwoPoint() {
        // 0.50 → 0.60 over 600 s = +0.10 per 600 s. Remaining 0.40 → 2400 s.
        let eta = MonitorUsageWidgetView.burnETASeconds(times: [0, 600], used: [0.50, 0.60])
        #expect(eta != nil)
        #expect(abs((eta ?? 0) - 2400) < 1.0)
    }

    @Test("burn ETA uses least-squares slope across many samples")
    func burnEtaLeastSquares() {
        // Perfectly linear +0.01 per 60 s → slope 1/6000 per s. From last=0.55,
        // remaining 0.45 → 0.45 · 6000 = 2700 s. A clean line makes LSQ == the
        // analytic slope.
        let times = (0..<6).map { Double($0) * 60 }
        let used = (0..<6).map { 0.50 + Double($0) * 0.01 }
        let eta = MonitorUsageWidgetView.burnETASeconds(times: times, used: used)
        #expect(eta != nil)
        #expect(abs((eta ?? 0) - 2700) < 5.0)
    }

    @Test("flat or falling series yields no ETA")
    func burnEtaNonPositiveSlope() {
        #expect(MonitorUsageWidgetView.burnETASeconds(times: [0, 600], used: [0.6, 0.6]) == nil)
        #expect(MonitorUsageWidgetView.burnETASeconds(times: [0, 600], used: [0.7, 0.4]) == nil)
    }

    @Test("already at the cap yields a zero ETA, not nil")
    func burnEtaAtCap() {
        let eta = MonitorUsageWidgetView.burnETASeconds(times: [0, 600], used: [0.98, 1.0])
        #expect(eta == 0)
    }

    @Test("ETA is clamped so a whisper-slow slope doesn't overflow the horizon")
    func burnEtaClamped() {
        // +0.00001 over 600 s → raw ETA ≈ 6.6M s; clamped to the cap.
        let eta = MonitorUsageWidgetView.burnETASeconds(times: [0, 600], used: [0.50, 0.50001])
        #expect(eta == MonitorUsageWidgetView.burnETAClampSeconds)
    }

    @Test("zero / negative dt between samples is ignored (no divide-by-zero)")
    func burnEtaGuardsBadTime() {
        // Same timestamp twice → no usable slope.
        #expect(MonitorUsageWidgetView.burnETASeconds(times: [600, 600], used: [0.4, 0.6]) == nil)
    }

    // MARK: - Quota escalation thresholds (ported quotaBand / quotaFill)

    @Test("near-limit dot band: warm ≥40%, crit >85%")
    func quotaBandThresholds() {
        #expect(MonitorUsageWidgetView.quotaBand(0.10) == .normal)
        #expect(MonitorUsageWidgetView.quotaBand(0.40) == .warm)
        #expect(MonitorUsageWidgetView.quotaBand(0.85) == .warm)
        #expect(MonitorUsageWidgetView.quotaBand(0.851) == .crit)
        #expect(MonitorUsageWidgetView.quotaBand(0.91) == .crit)
    }

    @Test("bar-fill escalation: warn >75%, crit >90%")
    func quotaFillThresholds() {
        #expect(MonitorUsageWidgetView.quotaFill(0.50) == .normal)
        #expect(MonitorUsageWidgetView.quotaFill(0.75) == .normal)
        #expect(MonitorUsageWidgetView.quotaFill(0.76) == .warn)
        #expect(MonitorUsageWidgetView.quotaFill(0.90) == .warn)
        #expect(MonitorUsageWidgetView.quotaFill(0.91) == .crit)
    }

    @Test("ETA critical flag flips at ≤15 min")
    func etaCriticalFlag() {
        #expect(MonitorUsageWidgetView.isETACritical(15 * 60) == true)
        #expect(MonitorUsageWidgetView.isETACritical(7 * 60) == true)
        #expect(MonitorUsageWidgetView.isETACritical(38 * 60) == false)
    }

    // MARK: - Cache four-segment fractions

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
        // Fractions sum to 1.
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
        let hit = MonitorUsageWidgetView.cacheHitRate(t)
        #expect(hit != nil)
        #expect(abs((hit ?? 0) - 5_210_000 / (1_180_000 + 5_210_000)) < 1e-9)
        // No reads at all → nil, not 0/0.
        #expect(MonitorUsageWidgetView.cacheHitRate(.zero) == nil)
    }

    // MARK: - Reset-countdown formatting choice

    @Test("5h reset uses short countdown, week reset uses days-aware countdown")
    func resetFormatting() {
        // 5h window: hours+minutes, no days.
        #expect(MonitorUsageWidgetView.fiveHourResetText(secondsRemaining: 2 * 3600 + 14 * 60) == "2h 14m")
        // Week window: days+hours.
        #expect(MonitorUsageWidgetView.weekResetText(secondsRemaining: 3 * 86400 + 5 * 3600) == "3d 5h")
    }

    // MARK: - Stale dimming

    @Test("stale dimming keyed on limitsStale == true only")
    func staleDimming() {
        #expect(MonitorUsageWidgetView.isLimitsStale(makeUsage(stale: true)) == true)
        #expect(MonitorUsageWidgetView.isLimitsStale(makeUsage(stale: false)) == false)
        #expect(MonitorUsageWidgetView.isLimitsStale(makeUsage(stale: nil)) == false)
    }

    @Test("quota blocks present only when the 5h fields exist")
    func quotaPresence() {
        #expect(MonitorUsageWidgetView.hasQuota(makeUsage(five: 0.58)) == true)
        #expect(MonitorUsageWidgetView.hasQuota(makeUsage(five: nil)) == false)
    }

    // MARK: - Per-model breakdown (L layout)

    @Test("model family is prefix-matched, unknown ids fall through to .other")
    func modelFamilyClassification() {
        #expect(MonitorUsageWidgetView.modelFamily("claude-opus-4-20250514") == .opus)
        #expect(MonitorUsageWidgetView.modelFamily("claude-sonnet-5") == .sonnet)
        #expect(MonitorUsageWidgetView.modelFamily("claude-3-5-haiku") == .haiku)
        #expect(MonitorUsageWidgetView.modelFamily("gpt-5-mini") == .gpt5mini)
        #expect(MonitorUsageWidgetView.modelFamily("gpt-5") == .gpt5)
        #expect(MonitorUsageWidgetView.modelFamily("some-local-model") == .other)
    }

    @Test("gpt-5-mini classifies before gpt-5 (order matters)")
    func modelFamilyMiniPrecedence() {
        // A bare "gpt-5" must NOT swallow the "-mini" suffix.
        #expect(MonitorUsageWidgetView.modelFamily("gpt-5-mini") == .gpt5mini)
        #expect(MonitorUsageWidgetView.modelFamily("gpt-5") == .gpt5)
    }

    @Test("known families collapse to friendly labels; unknown ids drop a build stamp")
    func modelShortName() {
        #expect(MonitorUsageWidgetView.modelShortName("claude-opus-4-20250514") == "Opus")
        #expect(MonitorUsageWidgetView.modelShortName("claude-sonnet-5") == "Sonnet")
        #expect(MonitorUsageWidgetView.modelShortName("gpt-5-mini") == "GPT-5 mini")
        // Unknown id keeps its name but trims a trailing "-<digits>" stamp.
        #expect(MonitorUsageWidgetView.modelShortName("my-model-20240101") == "my-model")
    }

    @Test("model tokens sums the four buckets")
    func modelTokens() {
        let m = MonitorUsageModelBreakdown(
            model: "claude-opus-4",
            tokens: MonitorTokenTotals(input: 100, output: 200, cacheRead: 300, cacheWrite: 400),
            costUSD: 1.0)
        #expect(MonitorUsageWidgetView.modelTokens(m) == 1000)
    }

    @Test("topModels returns the busiest few, nil when absent")
    func topModels() {
        var u = MonitorUsageSnapshot()
        #expect(MonitorUsageWidgetView.topModels(u) == nil)
        u.perModel = (0..<6).map { i in
            MonitorUsageModelBreakdown(model: "m\(i)",
                                       tokens: MonitorTokenTotals(input: 1000 - i * 100), costUSD: nil)
        }
        let top = MonitorUsageWidgetView.topModels(u, limit: 4)
        #expect(top?.count == 4)
        // Preserves the rollup's descending order (fixture is already sorted).
        #expect(top?.first?.model == "m0")
    }

    @Test("hasCache keys on non-zero today totals")
    func hasCache() {
        var u = MonitorUsageSnapshot()
        #expect(MonitorUsageWidgetView.hasCache(u) == false)
        u.tokensToday = .zero
        #expect(MonitorUsageWidgetView.hasCache(u) == false)
        u.tokensToday = MonitorTokenTotals(input: 5)
        #expect(MonitorUsageWidgetView.hasCache(u) == true)
    }

    // MARK: - `provider` / `primaryMetric` settings (read side)

    @Test("resolvedProvider defaults to \"all\", accepts claude/codex, rejects garbage")
    func resolvedProviderDefaults() {
        #expect(MonitorUsageWidgetView.resolvedProvider(nil) == "all")
        #expect(MonitorUsageWidgetView.resolvedProvider("") == "all")
        #expect(MonitorUsageWidgetView.resolvedProvider("bogus") == "all")
        #expect(MonitorUsageWidgetView.resolvedProvider("all") == "all")
        #expect(MonitorUsageWidgetView.resolvedProvider("claude") == "claude")
        #expect(MonitorUsageWidgetView.resolvedProvider("codex") == "codex")
    }

    @Test("resolvedPrimaryMetric defaults to \"tokens\", accepts cost, rejects garbage")
    func resolvedPrimaryMetricDefaults() {
        #expect(MonitorUsageWidgetView.resolvedPrimaryMetric(nil) == "tokens")
        #expect(MonitorUsageWidgetView.resolvedPrimaryMetric("") == "tokens")
        #expect(MonitorUsageWidgetView.resolvedPrimaryMetric("bogus") == "tokens")
        #expect(MonitorUsageWidgetView.resolvedPrimaryMetric("tokens") == "tokens")
        #expect(MonitorUsageWidgetView.resolvedPrimaryMetric("cost") == "cost")
    }

    @Test("costLeads is true only for the explicit cost metric")
    func costLeadsFlag() {
        #expect(MonitorUsageWidgetView.costLeads("cost") == true)
        #expect(MonitorUsageWidgetView.costLeads("tokens") == false)
    }

    @Test("quota is Claude-only data: hidden under codex, visible under all/claude")
    func quotaVisibleByProvider() {
        #expect(MonitorUsageWidgetView.quotaVisible("all") == true)
        #expect(MonitorUsageWidgetView.quotaVisible("claude") == true)
        #expect(MonitorUsageWidgetView.quotaVisible("codex") == false)
    }

    @Test("cross-provider aggregates (burn rate, trend, split bar) show only under all")
    func aggregatesVisibleByProvider() {
        #expect(MonitorUsageWidgetView.aggregatesVisible("all") == true)
        #expect(MonitorUsageWidgetView.aggregatesVisible("claude") == false)
        #expect(MonitorUsageWidgetView.aggregatesVisible("codex") == false)
    }

    // MARK: - Provider-scoped today totals

    @Test("filteredCostTodayUSD: all is unfiltered, claude/codex read perProvider")
    func filteredCostTodayUSDByProvider() {
        let u = makeProviderSplitUsage()
        #expect(MonitorUsageWidgetView.filteredCostTodayUSD(u, provider: "all") == 12.4)
        #expect(MonitorUsageWidgetView.filteredCostTodayUSD(u, provider: "claude") == 8.1)
        // Codex has no public per-token rate — perProvider["codex"].costTodayUSD
        // is always nil, and filtering must surface that honestly, not fabricate.
        #expect(MonitorUsageWidgetView.filteredCostTodayUSD(u, provider: "codex") == nil)
    }

    @Test("filteredCostTodayUSD is nil when perProvider is absent entirely")
    func filteredCostTodayUSDNoPerProvider() {
        var u = MonitorUsageSnapshot()
        u.costTodayUSD = 5
        #expect(MonitorUsageWidgetView.filteredCostTodayUSD(u, provider: "all") == 5)
        #expect(MonitorUsageWidgetView.filteredCostTodayUSD(u, provider: "claude") == nil)
    }

    @Test("filteredTokensToday: all is unfiltered, claude/codex read perProvider")
    func filteredTokensTodayByProvider() {
        let u = makeProviderSplitUsage()
        #expect(MonitorUsageWidgetView.filteredTokensToday(u, provider: "all")?.input == 5_700_000)
        #expect(MonitorUsageWidgetView.filteredTokensToday(u, provider: "claude")?.input == 3_800_000)
        #expect(MonitorUsageWidgetView.filteredTokensToday(u, provider: "codex")?.input == 1_900_000)
    }

    // MARK: - Per-model provider inference + filtering

    @Test("modelProvider: claude- prefix is Claude, everything else (gpt-5*, fallback \"codex\") is Codex")
    func modelProviderInference() {
        #expect(MonitorUsageWidgetView.modelProvider("claude-opus-4-20250514") == "claude")
        #expect(MonitorUsageWidgetView.modelProvider("claude-sonnet-5") == "claude")
        #expect(MonitorUsageWidgetView.modelProvider("gpt-5") == "codex")
        #expect(MonitorUsageWidgetView.modelProvider("gpt-5-mini") == "codex")
        // The Codex source's undetermined-model fallback literal.
        #expect(MonitorUsageWidgetView.modelProvider("codex") == "codex")
    }

    @Test("filteredPerModel: all is unfiltered, claude/codex drop the other provider's models")
    func filteredPerModelByProvider() {
        let u = makePerModelUsage()
        #expect(MonitorUsageWidgetView.filteredPerModel(u, provider: "all")?.count == 3)
        let claudeOnly = MonitorUsageWidgetView.filteredPerModel(u, provider: "claude")
        #expect(claudeOnly?.count == 2)
        #expect(claudeOnly?.allSatisfy { $0.model.hasPrefix("claude") } == true)
        let codexOnly = MonitorUsageWidgetView.filteredPerModel(u, provider: "codex")
        #expect(codexOnly?.count == 1)
        #expect(codexOnly?.first?.model == "gpt-5")
    }

    @Test("filteredPerModel is nil (not empty array) when nothing matches the filter")
    func filteredPerModelEmptyMatchIsNil() {
        var u = MonitorUsageSnapshot()
        u.perModel = [MonitorUsageModelBreakdown(model: "claude-sonnet-5", tokens: MonitorTokenTotals(input: 10), costUSD: 0.01)]
        #expect(MonitorUsageWidgetView.filteredPerModel(u, provider: "codex") == nil)
    }

    @Test("topModels(provider:) filters before applying the limit")
    func topModelsByProvider() {
        let u = makePerModelUsage()
        let claudeTop = MonitorUsageWidgetView.topModels(u, limit: 4, provider: "claude")
        #expect(claudeTop?.count == 2)
        #expect(MonitorUsageWidgetView.topModels(u, provider: "codex")?.first?.model == "gpt-5")
        // Default provider ("all") is unchanged from the pre-existing behaviour.
        #expect(MonitorUsageWidgetView.topModels(u, limit: 4)?.count == 3)
    }

    @Test("hasCache(provider:) matches the provider-scoped tokens, not the raw total")
    func hasCacheByProvider() {
        let u = makeProviderSplitUsage()
        #expect(MonitorUsageWidgetView.hasCache(u, provider: "all") == true)
        #expect(MonitorUsageWidgetView.hasCache(u, provider: "claude") == true)
        var noCodex = u
        noCodex.perProvider?["codex"] = nil
        #expect(MonitorUsageWidgetView.hasCache(noCodex, provider: "codex") == false)
    }

    // MARK: - Fixtures

    private func makeUsage(
        five: Double? = 0.58, stale: Bool? = false
    ) -> MonitorUsageSnapshot {
        var u = MonitorUsageSnapshot()
        u.fiveHourUsedPercent = five
        u.fiveHourResetsAt = five == nil ? nil : 1000
        u.limitsStale = stale
        return u
    }

    /// A snapshot with a real Claude/Codex `perProvider` split, mirroring the
    /// preview fixture's numbers (Codex cost intentionally nil — no public rate).
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

    /// A snapshot with a mixed-provider `perModel` breakdown (2 Claude models, 1 Codex).
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
