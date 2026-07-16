import AppKit
import SwiftUI
import Testing
@testable import LiveWallpaper

/// E1 characterization for AF-18. These tests deliberately describe the
/// current Usage widget presentation without asserting pixels, fonts, colors,
/// or private SwiftUI type structure. The value assertions pin the pure
/// derivations that a future app-local presentation policy may own; the small
/// accessibility smoke pins the user-facing size-tier and empty-state semantics.
@Suite("Monitor Usage presentation characterization", .serialized) @MainActor
struct MonitorUsagePresentationCharacterizationTests {
    @Test("S/M/L expose the current quota-forward semantic zones")
    func sizeTierSemanticZones() {
        let usage = populatedUsage()
        let history = risingHistory(current: usage.fiveHourUsedPercent ?? 0)

        let small = accessibilityText(size: .small, usage: usage, history: history)
        expectContains(small, ["USAGE", "5H", "Week", "TODAY", "$12.4"])
        expectExcludes(small, ["TO 5H LIMIT", "PER-MODEL", "BURN $/h", "7-DAY TOKENS"])

        let medium = accessibilityText(size: .medium, usage: usage, history: history)
        expectContains(medium, [
            "USAGE", "live", "TODAY $", "TOKENS", "CACHE",
            "5H limit", "Week", "TO 5H LIMIT", "7-DAY TOKENS",
            "Claude", "Codex",
        ])
        expectExcludes(medium, ["PER-MODEL", "BURN $/h", "BURN tok/h"])

        let large = accessibilityText(size: .large, usage: usage, history: history)
        expectContains(large, [
            "USAGE", "live", "TODAY $", "TOKENS", "BURN $/h", "BURN tok/h",
            "5H limit", "Week", "TO 5H LIMIT", "PER-MODEL", "CACHE",
            "7-DAY TOKENS",
        ])
    }

    @Test("missing usage keeps size-specific recovery copy and authorization guidance")
    func missingUsageRecoveryCopy() {
        let small = accessibilityText(size: .small, usage: nil)
        expectContains(small, ["USAGE", "No usage yet", "Run an agent to track tokens."])

        for size in [MonitorWidgetSize.medium, .large] {
            let text = accessibilityText(size: size, usage: nil)
            expectContains(text, [
                "USAGE", "No usage yet",
                "Session token & cost tracking starts automatically once an agent runs.",
            ])
        }

        for size in MonitorWidgetSize.allCases {
            let text = accessibilityText(size: size, usage: nil, unauthorized: true)
            expectContains(text, [
                "USAGE", "No usage yet",
                "Authorize the agent folders in Monitor settings.",
            ])
            expectExcludes(text, [
                "Run an agent to track tokens.",
                "Session token & cost tracking starts automatically once an agent runs.",
            ])
        }
    }

    @Test("stale quota remains visible but suppresses burn ETA")
    func staleQuotaPresentation() {
        var usage = populatedUsage()
        usage.limitsStale = true
        let history = risingHistory(current: usage.fiveHourUsedPercent ?? 0)

        let small = accessibilityText(size: .small, usage: usage, history: history)
        expectContains(small, ["USAGE", "5H", "Week"])
        expectExcludes(small, ["5H RESETS", "TO 5H LIMIT"])

        for size in [MonitorWidgetSize.medium, .large] {
            let text = accessibilityText(size: size, usage: usage, history: history)
            expectContains(text, ["USAGE", "stale", "5H limit", "Week"])
            expectExcludes(text, ["TO 5H LIMIT"])
        }
    }

    @Test("provider scoping preserves honest missing-data semantics")
    func providerScopingSnapshot() {
        let usage = populatedUsage()

        #expect(MonitorUsageWidgetView.resolvedProvider(nil) == "all")
        #expect(MonitorUsageWidgetView.resolvedProvider("expired-value") == "all")

        let claude = providerSnapshot(usage, provider: "claude")
        #expect(claude == ProviderSnapshot(
            quotaVisible: true,
            aggregatesVisible: false,
            costTodayUSD: 8.1,
            tokenTotal: 5_680_000,
            modelNames: ["claude-opus-4-20250514", "claude-sonnet-5"],
            hasCache: true
        ))

        let codex = providerSnapshot(usage, provider: "codex")
        #expect(codex == ProviderSnapshot(
            quotaVisible: false,
            aggregatesVisible: false,
            costTodayUSD: nil,
            tokenTotal: 2_740_000,
            modelNames: ["gpt-5"],
            hasCache: true
        ))

        var missingProvider = usage
        missingProvider.perProvider?["codex"] = nil
        let missing = providerSnapshot(missingProvider, provider: "codex")
        #expect(missing.costTodayUSD == nil)
        #expect(missing.tokenTotal == nil)
        #expect(missing.hasCache == false)
    }

    @Test("quota and ETA thresholds pin exact, out-of-range, and non-finite inputs")
    func quotaAndETABoundaries() {
        let epsilon = 0.000_001
        #expect(MonitorUsageWidgetView.quotaBand(-1) == .normal)
        #expect(MonitorUsageWidgetView.quotaBand(.nan) == .normal)
        #expect(MonitorUsageWidgetView.quotaBand(.infinity) == .normal)
        #expect(MonitorUsageWidgetView.quotaBand(0.40 - epsilon) == .normal)
        #expect(MonitorUsageWidgetView.quotaBand(0.40) == .warm)
        #expect(MonitorUsageWidgetView.quotaBand(0.85) == .warm)
        #expect(MonitorUsageWidgetView.quotaBand(0.85 + epsilon) == .crit)
        #expect(MonitorUsageWidgetView.quotaBand(2) == .crit)

        #expect(MonitorUsageWidgetView.quotaFill(0.75) == .normal)
        #expect(MonitorUsageWidgetView.quotaFill(0.75 + epsilon) == .warn)
        #expect(MonitorUsageWidgetView.quotaFill(0.90) == .warn)
        #expect(MonitorUsageWidgetView.quotaFill(0.90 + epsilon) == .crit)

        // The helper owns the complete user-facing percent token. A separate
        // glyph at the call site would therefore duplicate the unit.
        #expect(MonitorUsageWidgetView.wholePercent(-1) == "0%")
        #expect(MonitorUsageWidgetView.wholePercent(0.58) == "58%")
        #expect(MonitorUsageWidgetView.wholePercent(2) == "100%")
        #expect(MonitorUsageWidgetView.wholePercent(.nan) == "0%")
        #expect(MonitorUsageWidgetView.wholePercentValue(-1) == "0")
        #expect(MonitorUsageWidgetView.wholePercentValue(0.58) == "58")
        #expect(MonitorUsageWidgetView.wholePercentValue(2) == "100")

        #expect(MonitorUsageWidgetView.isETACritical(15 * 60) == true)
        #expect(MonitorUsageWidgetView.isETACritical(15 * 60 + epsilon) == false)
        #expect(MonitorUsageWidgetView.isETACritical(.infinity) == false)

        #expect(MonitorUsageWidgetView.burnETASeconds(times: [0, 60], used: [0.5]) == nil)
        #expect(MonitorUsageWidgetView.burnETASeconds(times: [0, 60], used: [0.5, .nan]) == nil)
        #expect(MonitorUsageWidgetView.burnETASeconds(times: [0, 60], used: [1.1, 1.2]) == 0)
        #expect(MonitorUsageWidgetView.burnETASeconds(
            times: [0, 600], used: [0.5, 0.500_01]
        ) == MonitorUsageWidgetView.burnETAClampSeconds)
    }

    @Test("remaining-time copy clamps expired and non-finite resets")
    func remainingTimeBoundaries() {
        #expect(MonitorUsageWidgetView.fiveHourResetText(secondsRemaining: -1) == "0s")
        #expect(MonitorUsageWidgetView.fiveHourResetText(secondsRemaining: .nan) == "0s")
        #expect(MonitorUsageWidgetView.fiveHourResetText(secondsRemaining: 59) == "59s")
        #expect(MonitorUsageWidgetView.fiveHourResetText(secondsRemaining: 60) == "1m")
        #expect(MonitorUsageWidgetView.fiveHourResetText(secondsRemaining: 3_661) == "1h 1m")

        #expect(MonitorUsageWidgetView.weekResetText(secondsRemaining: -1) == "0s")
        #expect(MonitorUsageWidgetView.weekResetText(secondsRemaining: 86_399) == "23h 59m")
        #expect(MonitorUsageWidgetView.weekResetText(secondsRemaining: 86_400) == "1d 0h")
    }

    private struct ProviderSnapshot: Equatable {
        var quotaVisible: Bool
        var aggregatesVisible: Bool
        var costTodayUSD: Double?
        var tokenTotal: Int?
        var modelNames: [String]?
        var hasCache: Bool
    }

    private func providerSnapshot(
        _ usage: MonitorUsageSnapshot,
        provider: String
    ) -> ProviderSnapshot {
        let tokens = MonitorUsageWidgetView.filteredTokensToday(usage, provider: provider)
        return ProviderSnapshot(
            quotaVisible: MonitorUsageWidgetView.quotaVisible(provider),
            aggregatesVisible: MonitorUsageWidgetView.aggregatesVisible(provider),
            costTodayUSD: MonitorUsageWidgetView.filteredCostTodayUSD(usage, provider: provider),
            // The presentation's TOKENS readout intentionally excludes cache
            // traffic; keep this policy snapshot aligned with that visible sum.
            tokenTotal: tokens.map { $0.input + $0.output },
            modelNames: MonitorUsageWidgetView.filteredPerModel(usage, provider: provider)?.map(\.model),
            hasCache: MonitorUsageWidgetView.hasCache(usage, provider: provider)
        )
    }

    private func populatedUsage() -> MonitorUsageSnapshot {
        var usage = MonitorUsageSnapshot()
        usage.fiveHourUsedPercent = 0.58
        usage.fiveHourResetsAt = 10_000 + 2 * 3_600 + 14 * 60
        usage.weekUsedPercent = 0.63
        usage.weekResetsAt = 10_000 + 3 * 86_400 + 5 * 3_600
        usage.costTodayUSD = 12.4
        usage.tokensToday = MonitorTokenTotals(
            input: 5_700_000,
            output: 2_720_000,
            cacheRead: 5_210_000,
            cacheWrite: 1_070_000
        )
        usage.perProvider = [
            "claude": MonitorProviderUsage(
                costTodayUSD: 8.1,
                tokensToday: MonitorTokenTotals(
                    input: 3_800_000, output: 1_880_000,
                    cacheRead: 2_100_000, cacheWrite: 420_000
                )
            ),
            "codex": MonitorProviderUsage(
                costTodayUSD: nil,
                tokensToday: MonitorTokenTotals(
                    input: 1_900_000, output: 840_000,
                    cacheRead: 730_000, cacheWrite: 180_000
                )
            ),
        ]
        usage.limitsStale = false
        usage.dailyActivity = [4.1, 6.8, 3.2, 9.4, 7.1, 5.5, 8.42].map { value in
            MonitorUsageDayBucket(
                day: "2026-07-01",
                tokens: MonitorTokenTotals(input: Int(value * 1_000_000))
            )
        }
        usage.tokenBurnRatePerHour = 1_240_000
        usage.costBurnRatePerHour = 2.6
        usage.perModel = [
            MonitorUsageModelBreakdown(
                model: "claude-opus-4-20250514",
                tokens: MonitorTokenTotals(input: 3_100_000),
                costUSD: 8.1
            ),
            MonitorUsageModelBreakdown(
                model: "gpt-5",
                tokens: MonitorTokenTotals(input: 1_400_000),
                costUSD: nil
            ),
            MonitorUsageModelBreakdown(
                model: "claude-sonnet-5",
                tokens: MonitorTokenTotals(input: 900_000),
                costUSD: 1.2
            ),
        ]
        return usage
    }

    private func risingHistory(current: Double) -> MonitorHistorySnapshot {
        var history = MonitorHistorySnapshot()
        let step = 0.011
        for index in 0..<6 {
            history.usageQuotaTimes.append(Double(index) * 120)
            history.usageFiveHourUsed.append(current - 0.05 + Double(index) * step)
        }
        return history
    }

    private func accessibilityText(
        size: MonitorWidgetSize,
        usage: MonitorUsageSnapshot?,
        history: MonitorHistorySnapshot = MonitorHistorySnapshot(),
        provider: String = "all",
        unauthorized: Bool = false
    ) -> String {
        var snapshot = MonitorSnapshot(timestamp: 10_000)
        snapshot.usage = usage
        if unauthorized {
            snapshot.health = [MonitorSourceHealth(
                sourceID: "claude",
                state: "unauthorized",
                detail: nil,
                lastUpdateAt: nil
            )]
        }
        let placement = MonitorWidgetPlacement(
            kind: .usage,
            size: size,
            options: ["provider": .string(provider)]
        )
        let context = MonitorWidgetContext(
            snapshot: snapshot,
            history: history,
            placement: placement,
            isEditing: false,
            isAgentFleetEnabled: true,
            reduceMotion: true,
            now: Date(timeIntervalSince1970: 10_000)
        )
        let dimensions = dimensions(for: size)
        let root = MonitorUsageWidgetView(context: context)
            .environment(\.locale, Locale(identifier: "en_US"))
            .frame(width: dimensions.width, height: dimensions.height)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: dimensions)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        var values: [String] = []
        collectAccessibilityText(from: host, depth: 0, into: &values)
        window.contentView = nil
        return values.joined(separator: " | ")
    }

    private func collectAccessibilityText(
        from element: Any,
        depth: Int,
        into values: inout [String]
    ) {
        guard depth < 24 else { return }

        let label: String?
        let value: Any?
        let children: [Any]
        switch element {
        case let view as NSView:
            label = view.accessibilityLabel()
            value = view.accessibilityValue()
            children = view.accessibilityChildren() ?? []
        case let accessibilityElement as NSAccessibilityElement:
            label = accessibilityElement.accessibilityLabel()
            value = accessibilityElement.accessibilityValue()
            children = accessibilityElement.accessibilityChildren() ?? []
        default:
            return
        }

        if let label, !label.isEmpty {
            values.append(label)
        }
        if let value = value as? String, !value.isEmpty {
            values.append(value)
        }
        for child in children {
            collectAccessibilityText(from: child, depth: depth + 1, into: &values)
        }
    }

    private func dimensions(for size: MonitorWidgetSize) -> CGSize {
        switch size {
        case .small: return CGSize(width: 170, height: 170)
        case .medium: return CGSize(width: 364, height: 170)
        case .large: return CGSize(width: 364, height: 376)
        }
    }

    private func expectContains(
        _ snapshot: String,
        _ fragments: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for fragment in fragments {
            #expect(
                snapshot.localizedCaseInsensitiveContains(fragment),
                "Missing \(fragment.debugDescription) in AX snapshot: \(snapshot)",
                sourceLocation: sourceLocation
            )
        }
    }

    private func expectExcludes(
        _ snapshot: String,
        _ fragments: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for fragment in fragments {
            #expect(
                !snapshot.localizedCaseInsensitiveContains(fragment),
                "Unexpected \(fragment.debugDescription) in AX snapshot: \(snapshot)",
                sourceLocation: sourceLocation
            )
        }
    }
}
