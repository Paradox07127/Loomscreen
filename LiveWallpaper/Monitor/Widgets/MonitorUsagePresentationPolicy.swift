import Foundation
import LiveWallpaperCore

/// Snapshot-derived Usage decisions. This stays independent of SwiftUI and of
/// Monitor host ownership so the widget only renders an already-defined policy.
enum MonitorUsagePresentationPolicy {
    enum Band: Equatable { case normal, warm, warn, crit }

    static func quotaBand(_ fraction: Double) -> Band {
        let f = clampUnit(fraction)
        if f > 0.85 { return .crit }
        if f >= 0.40 { return .warm }
        return .normal
    }

    static func quotaFill(_ fraction: Double) -> Band {
        let f = clampUnit(fraction)
        if f > 0.90 { return .crit }
        if f > 0.75 { return .warn }
        return .normal
    }

    static func isETACritical(_ seconds: Double) -> Bool {
        seconds <= 15 * 60
    }

    static func wholePercent(_ fraction: Double) -> String {
        "\(wholePercentValue(fraction))%"
    }

    static func wholePercentValue(_ fraction: Double) -> String {
        "\(Int((clampUnit(fraction) * 100).rounded()))"
    }

    static func isLimitsStale(_ usage: MonitorUsageSnapshot) -> Bool {
        usage.limitsStale == true
    }

    static func hasQuota(_ usage: MonitorUsageSnapshot) -> Bool {
        usage.fiveHourUsedPercent != nil
    }

    static func resolvedProvider(_ raw: String?) -> String {
        switch raw {
        case "claude", "codex": return raw!
        default: return "all"
        }
    }

    static func resolvedPrimaryMetric(_ raw: String?) -> String {
        raw == "cost" ? "cost" : "tokens"
    }

    static func costLeads(_ primaryMetric: String) -> Bool {
        primaryMetric == "cost"
    }

    static func quotaVisible(_ provider: String) -> Bool {
        provider != "codex"
    }

    static func aggregatesVisible(_ provider: String) -> Bool {
        provider == "all"
    }

    static func filteredCostTodayUSD(
        _ usage: MonitorUsageSnapshot, provider: String
    ) -> Double? {
        provider == "all" ? usage.costTodayUSD : usage.perProvider?[provider]?.costTodayUSD
    }

    static func filteredTokensToday(
        _ usage: MonitorUsageSnapshot, provider: String
    ) -> MonitorTokenTotals? {
        provider == "all" ? usage.tokensToday : usage.perProvider?[provider]?.tokensToday
    }

    static func modelProvider(_ model: String) -> String {
        model.lowercased().hasPrefix("claude") ? "claude" : "codex"
    }

    static func filteredPerModel(
        _ usage: MonitorUsageSnapshot, provider: String
    ) -> [MonitorUsageModelBreakdown]? {
        guard let models = usage.perModel, !models.isEmpty else { return nil }
        guard provider != "all" else { return models }
        let filtered = models.filter { modelProvider($0.model) == provider }
        return filtered.isEmpty ? nil : filtered
    }

    static func fiveHourResetText(secondsRemaining: Double) -> String {
        MonitorFormat.countdown(secondsRemaining)
    }

    static func weekResetText(secondsRemaining: Double) -> String {
        MonitorFormat.countdownDays(secondsRemaining)
    }

    static func burnETASeconds(times: [Double], used: [Double]) -> Double? {
        guard times.count == used.count, used.count >= 2 else { return nil }
        guard let last = used.last else { return nil }
        let currentUsed = clampUnit(last)
        if currentUsed >= 1.0 { return 0 }

        let n = Double(used.count)
        let meanT = times.reduce(0, +) / n
        let meanU = used.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for index in used.indices {
            let deltaTime = times[index] - meanT
            numerator += deltaTime * (used[index] - meanU)
            denominator += deltaTime * deltaTime
        }
        guard denominator > 0 else { return nil }
        let slopePerSecond = numerator / denominator
        guard slopePerSecond > 0 else { return nil }

        let rawETA = (1.0 - currentUsed) / slopePerSecond
        guard rawETA.isFinite, rawETA >= 0 else { return nil }
        return min(rawETA, burnETAClampSeconds)
    }

    static let burnETAClampSeconds: Double = 24 * 3600

    static func cacheHitRate(_ tokens: MonitorTokenTotals) -> Double? {
        let denominator = tokens.input + tokens.cacheRead
        guard denominator > 0 else { return nil }
        return Double(tokens.cacheRead) / Double(denominator)
    }

    struct ProviderSplit: Equatable {
        var claudeCost: Double
        var codexCost: Double

        var claudeShare: Double {
            let total = claudeCost + codexCost
            return total > 0 ? claudeCost / total : 0.5
        }
    }

    static func providerSplit(_ usage: MonitorUsageSnapshot) -> ProviderSplit? {
        guard let providers = usage.perProvider else { return nil }
        let claude = providers["claude"]?.costTodayUSD ?? 0
        let codex = providers["codex"]?.costTodayUSD ?? 0
        guard claude > 0 || codex > 0 else { return nil }
        return ProviderSplit(claudeCost: claude, codexCost: codex)
    }

    static func week7Tokens(_ usage: MonitorUsageSnapshot) -> [Double]? {
        guard let daily = usage.dailyActivity, !daily.isEmpty else { return nil }
        return daily.suffix(7).map { Double($0.tokens.input + $0.tokens.output) }
    }

    static func hasCache(_ usage: MonitorUsageSnapshot) -> Bool {
        guard let tokens = usage.tokensToday else { return false }
        return tokens != .zero
    }

    static func hasCache(_ usage: MonitorUsageSnapshot, provider: String) -> Bool {
        guard let tokens = filteredTokensToday(usage, provider: provider) else { return false }
        return tokens != .zero
    }

    static func modelTokens(_ model: MonitorUsageModelBreakdown) -> Int {
        model.tokens.input + model.tokens.output + model.tokens.cacheRead + model.tokens.cacheWrite
    }

    static func topModels(
        _ usage: MonitorUsageSnapshot, limit: Int = 4, provider: String = "all"
    ) -> [MonitorUsageModelBreakdown]? {
        guard let models = filteredPerModel(usage, provider: provider) else { return nil }
        return Array(models.prefix(max(1, limit)))
    }

    enum ModelFamily: Equatable { case opus, sonnet, haiku, gpt5, gpt5mini, other }

    static func modelFamily(_ model: String) -> ModelFamily {
        let id = model.lowercased()
        if id.contains("opus") { return .opus }
        if id.contains("sonnet") { return .sonnet }
        if id.contains("haiku") { return .haiku }
        if id.contains("gpt-5-mini") || id.contains("gpt-5m") || id.contains("mini") { return .gpt5mini }
        if id.contains("gpt-5") || id.contains("gpt5") || id.hasPrefix("gpt") { return .gpt5 }
        return .other
    }

    static func modelShortName(_ model: String) -> String {
        switch modelFamily(model) {
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        case .gpt5: return "GPT-5"
        case .gpt5mini: return "GPT-5 mini"
        case .other:
            var name = model
            if let range = name.range(of: "-[0-9]{4,}$", options: .regularExpression) {
                name.removeSubrange(range)
            }
            return name.count > 16 ? String(name.prefix(15)) + "…" : name
        }
    }

    private static func clampUnit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}
