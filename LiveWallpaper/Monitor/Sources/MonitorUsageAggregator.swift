import Foundation

/// Shared token pricing keyed by model-id prefix, in USD per 1M tokens.
enum MonitorTokenPricing {
    struct Rate: Equatable {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }

    static func rate(for model: String) -> Rate? {
        let id = model.lowercased()
        if id.hasPrefix("claude-opus-4") || id == "opus" {
            return Rate(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)
        }
        if id.hasPrefix("claude-sonnet-5") || id.hasPrefix("claude-sonnet-4")
            || id.hasPrefix("claude-3-5-sonnet") || id == "sonnet" {
            return Rate(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
        }
        if id.hasPrefix("claude-haiku") || id.hasPrefix("claude-3-5-haiku") || id == "haiku" {
            return Rate(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)
        }
        return nil
    }

    static func cost(model: String, tokens: MonitorTokenTotals) -> Double? {
        guard let rate = rate(for: model) else { return nil }
        let perMTok = 1_000_000.0
        return (Double(tokens.input) * rate.input
              + Double(tokens.output) * rate.output
              + Double(tokens.cacheRead) * rate.cacheRead
              + Double(tokens.cacheWrite) * rate.cacheWrite) / perMTok
    }
}

/// Per-file usage extracted from a transcript, bucketed by (localDay, model).
struct MonitorFileUsageBuckets: Equatable, Sendable {
    /// `[localDay("YYYY-MM-DD"): [model: tokens]]`.
    var byDayModel: [String: [String: MonitorTokenTotals]] = [:]

    var isEmpty: Bool { byDayModel.isEmpty }

    mutating func add(day: String, model: String, tokens: MonitorTokenTotals) {
        guard tokens != .zero else { return }
        var models = byDayModel[day] ?? [:]
        models[model, default: .zero] = (models[model] ?? .zero) + tokens
        byDayModel[day] = models
    }
}

/// Identity fingerprint for the per-file memo cache — the trio the tail pipeline
/// already stats. A changed size or mtime invalidates the cached buckets.
struct MonitorUsageFileFingerprint: Hashable, Sendable {
    var pathHash: Int
    var size: UInt64
    var mtime: Double
}

/// Rolls per-file daily buckets into `MonitorUsageSnapshot.perModel` + `.dailyActivity`, restricted to the trailing `dayWindow` local-calendar days including today.
enum MonitorUsageRollup {
    static let dayWindow = 14

    /// Local-calendar day key for an epoch time.
    static func dayKey(_ epoch: Double, calendar: Calendar = .current) -> String {
        Self.dayFormatter(calendar).string(from: Date(timeIntervalSince1970: epoch))
    }

    /// The set of day keys for the trailing `days` window ending on `now`'s day.
    static func windowDays(now: Double, days: Int = dayWindow, calendar: Calendar = .current) -> [String] {
        let formatter = dayFormatter(calendar)
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        var keys: [String] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            if let day = calendar.date(byAdding: .day, value: -offset, to: today) {
                keys.append(formatter.string(from: day))
            }
        }
        return keys
    }

    /// Compose the model + day breakdowns from already-extracted per-file buckets.
    static func compose(
        files: [MonitorFileUsageBuckets],
        now: Double,
        days: Int = dayWindow,
        calendar: Calendar = .current
    ) -> (perModel: [MonitorUsageModelBreakdown]?, dailyActivity: [MonitorUsageDayBucket]?) {
        let windowSet = Set(windowDays(now: now, days: days, calendar: calendar))
        var modelTotals: [String: MonitorTokenTotals] = [:]
        var dayTotals: [String: MonitorTokenTotals] = [:]

        for file in files {
            for (day, models) in file.byDayModel where windowSet.contains(day) {
                for (model, tokens) in models {
                    modelTotals[model, default: .zero] = (modelTotals[model] ?? .zero) + tokens
                    dayTotals[day, default: .zero] = (dayTotals[day] ?? .zero) + tokens
                }
            }
        }

        let perModel: [MonitorUsageModelBreakdown]? = modelTotals.isEmpty ? nil : modelTotals
            .map { model, tokens in
                MonitorUsageModelBreakdown(
                    model: model,
                    tokens: tokens,
                    costUSD: MonitorTokenPricing.cost(model: model, tokens: tokens)
                )
            }
            .sorted { lhs, rhs in
                let l = lhs.tokens.input + lhs.tokens.output + lhs.tokens.cacheRead + lhs.tokens.cacheWrite
                let r = rhs.tokens.input + rhs.tokens.output + rhs.tokens.cacheRead + rhs.tokens.cacheWrite
                if l != r { return l > r }
                return lhs.model < rhs.model
            }

        let orderedDays = windowDays(now: now, days: days, calendar: calendar)
        var dayCost: [String: Double] = [:]
        for file in files {
            for (day, models) in file.byDayModel where windowSet.contains(day) {
                for (model, tokens) in models {
                    if let cost = MonitorTokenPricing.cost(model: model, tokens: tokens) {
                        dayCost[day, default: 0] += cost
                    }
                }
            }
        }
        let anyActivity = !dayTotals.isEmpty
        let dailyActivity: [MonitorUsageDayBucket]? = anyActivity ? orderedDays.map { day in
            MonitorUsageDayBucket(
                day: day,
                tokens: dayTotals[day] ?? .zero,
                costUSD: dayCost[day]
            )
        } : nil

        return (perModel, dailyActivity)
    }

    private static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// Windowed burn-rate estimator over scan cycles.
struct MonitorBurnRateWindow {
    struct Sample: Equatable { var at: Double; var tokens: Double; var cost: Double? }

    private var samples: [Sample] = []
    private let window: TimeInterval
    private let minSpan: TimeInterval

    init(window: TimeInterval = 30 * 60, minSpan: TimeInterval = 2 * 60) {
        self.window = window
        self.minSpan = minSpan
    }

    /// Record cumulative counters at `at` and prune anything older than `window`.
    mutating func record(at: Double, cumulativeTokens: Int, cumulativeCost: Double?) {
        samples.append(Sample(at: at, tokens: Double(cumulativeTokens), cost: cumulativeCost))
        let cutoff = at - window
        samples.removeAll { $0.at < cutoff }
        if let last = samples.last {
            if let dropIndex = samples.dropLast().lastIndex(where: { $0.tokens > last.tokens }) {
                samples.removeSubrange(samples.startIndex...dropIndex)
            }
        }
    }

    /// (tokens/hour, cost/hour) over the retained window, or nil components until
    /// the window spans `minSpan` and shows positive movement.
    func rates() -> (tokensPerHour: Double?, costPerHour: Double?) {
        guard let first = samples.first, let last = samples.last else { return (nil, nil) }
        let span = last.at - first.at
        guard span >= minSpan else { return (nil, nil) }
        let hours = span / 3600
        guard hours > 0 else { return (nil, nil) }

        let tokenDelta = last.tokens - first.tokens
        let tokensPerHour = tokenDelta > 0 ? tokenDelta / hours : nil

        var costPerHour: Double?
        if let firstCost = first.cost, let lastCost = last.cost {
            let costDelta = lastCost - firstCost
            costPerHour = costDelta > 0 ? costDelta / hours : nil
        }
        return (tokensPerHour, costPerHour)
    }
}
