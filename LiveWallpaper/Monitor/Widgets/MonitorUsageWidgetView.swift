import SwiftUI
import LiveWallpaperCore

/// Usage widget — a native replica of the mock's `usage_s` / `usage_m`
/// (`.claude/plan/monitor-design/index.html`, §3.2.6 density directive) plus a
/// real L "ledger-lite" panel (the mock cut L to the Usage Ledger §3.2.8; here L
/// is a glance-sized instrument stack grounded in the same snapshot fields).
/// The #1 glance: "will I hit the limit?" QUOTA-FORWARD. The 5h quota ring is the
/// hero (the ONE shared `ArcGauge`), the week meter and today $/tokens frame it,
/// and M densifies into a CodexBar-popover-class cockpit: dual 5h/week meters +
/// dual reset countdowns + provider split + a client-derived burn ETA + a
/// one-line four-segment cache row + a 7-day mini sparkline. L adds the two things M has
/// no room for — the client burn-rate readouts ($/h, tok/h) and a per-model
/// breakdown (share bar + valued rows from `perModel`) — over the same quota
/// hero, cache strip and 7-day trend.
///
/// SPEC §3.4 honesty: `fiveHour/weekUsedPercent` + resets come from the statusline
/// rate-limit capture; `tokensToday/costTodayUSD` are the free local JSONL tail;
/// the burn ETA is client-derived from the sparse `history.usageFiveHourUsed`
/// slope and is shown ONLY when honestly derivable. `limitsStale` dims the quota
/// block (numbers stay visible); missing 5h fields drop the quota blocks entirely
/// while today-consumption still shows; a nil `usage` is a quiet setup-needed state.
struct MonitorUsageWidgetView: View {
    let context: MonitorWidgetContext

    private var usage: MonitorUsageSnapshot? { context.snapshot.usage }
    private var history: MonitorHistorySnapshot { context.history }

    /// `provider` (placement.options): scopes perProvider/perModel/today totals
    /// to a single provider. Invalid/missing ⇒ "all" (unfiltered — the widget's
    /// pre-existing rendering, unchanged).
    private var provider: String {
        Self.resolvedProvider(context.placement.options["provider"]?.stringValue)
    }

    /// `primaryMetric` (placement.options): which of cost/tokens leads the
    /// hero-summary and per-model rows. Invalid/missing ⇒ "tokens" (default —
    /// today's rendering, unchanged).
    private var primaryMetric: String {
        Self.resolvedPrimaryMetric(context.placement.options["primaryMetric"]?.stringValue)
    }

    var body: some View {
        GeometryReader { geo in
            // Board convention (see CPU): S/M span one board row and L two, so
            // dividing by 2·rowSpan yields the mock's near-constant cell height
            // (85/94) — one type scale across all sizes.
            let rowSpan: CGFloat = context.placement.size == .large ? 2 : 1
            let cellHeight = geo.size.height / (2 * rowSpan)
            MonitorWidgetContainer(
                label: "Usage",
                systemImage: "gauge.with.needle",
                cellHeight: cellHeight,
                status: { headerStatus(cellHeight: cellHeight) },
                content: {
                    if let usage {
                        switch context.placement.size {
                        case .small: smallBody(usage, cellHeight: cellHeight)
                        case .medium: mediumBody(usage, cellHeight: cellHeight)
                        case .large: largeBody(usage, cellHeight: cellHeight)
                        }
                    } else {
                        setupNeeded(cellHeight: cellHeight)
                    }
                }
            )
        }
    }

    // MARK: - Header status

    /// S mirrors `chd("USAGE", "5h resets …")`; M mirrors the `.pstat` live pill.
    @ViewBuilder
    private func headerStatus(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        if let usage {
            switch context.placement.size {
            case .small:
                if let resets = usage.fiveHourResetsAt, Self.hasQuota(usage), Self.quotaVisible(provider),
                   !Self.isLimitsStale(usage) {
                    // "5H RESETS <time>" — localized whole, the countdown a placeholder.
                    Text(verbatim: String(localized: "5H RESETS \(Self.fiveHourResetText(secondsRemaining: resets - nowEpoch))",
                                          comment: "Usage widget S header: when the 5-hour quota resets; %@ is a countdown."))
                        .font(MonitorDesign.labelFont(size: scale.label))
                        .tracking(MonitorDesign.labelTracking(size: scale.label))
                        .foregroundStyle(MonitorDesign.inkFaint)
                        // ~16 tracked chars beside "USAGE" won't fit the fixed
                        // 170 pt tile's header; shrink before truncating.
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    providerStatusPill(usage, scale: scale, showLabel: false)
                }
            case .medium, .large:
                providerStatusPill(usage, scale: scale, showLabel: true)
            }
        }
    }

    /// The provider status dot + optional word ("live" / "stale" / "degraded").
    /// Labelled (M/L header) it reads as a contained status chip; dot-only (S)
    /// stays bare — a lone dot needs no capsule.
    @ViewBuilder
    private func providerStatusPill(
        _ usage: MonitorUsageSnapshot, scale: MonitorDesign.TypeScale, showLabel: Bool
    ) -> some View {
        let status = Self.providerStatus(usage)
        let pill = HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: scale.label * 0.55, height: scale.label * 0.55)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                .shadow(color: status.color.opacity(0.6), radius: 3)
            if showLabel {
                Text(verbatim: status.label)
                    .font(MonitorDesign.subFont(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkMuted)
            }
        }
        if showLabel {
            pill.monitorChip(scale)
        } else {
            pill
        }
    }

    private var nowEpoch: Double { context.now.timeIntervalSince1970 }

    // MARK: - S (170×170 — content ≈ 138×125)

    /// S content budget ≈ 138×125 pt: ring 76 + week meter (~20) + today row
    /// (~13) + two gaps. Staleness reads via the dimmed quota + the amber status
    /// dots (header + today row) — a dedicated marker row no longer fits.
    @ViewBuilder
    private func smallBody(_ usage: MonitorUsageSnapshot, cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let stale = Self.isLimitsStale(usage)
        VStack(alignment: .leading, spacing: scale.label * 0.5) {
            if Self.hasQuota(usage) && Self.quotaVisible(provider) {
                quotaRingHero(usage, scale: scale, hubHeroScale: 0.78)
                    .opacity(stale ? 0.5 : 1)
                weekMicroMeter(usage, scale: scale)
                    .opacity(stale ? 0.5 : 1)
            } else {
                Spacer(minLength: 0)
            }
            todayRowCompact(usage, scale: scale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The 5h quota ring hero: shared `ArcGauge(fiveHourUsedPercent)` with the
    /// used% woven into the hub + a "5H" label. Band colour follows the near-limit
    /// escalation so >85% goes coral.
    private func quotaRingHero(
        _ usage: MonitorUsageSnapshot, scale: MonitorDesign.TypeScale, hubHeroScale: CGFloat
    ) -> some View {
        let pct = usage.fiveHourUsedPercent ?? 0
        return HStack {
            Spacer(minLength: 0)
            ArcGauge(value: pct, color: Self.quotaBandColor(pct)) {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(verbatim: Self.wholePercentValue(pct))
                            .font(MonitorDesign.heroFont(size: scale.hero * hubHeroScale))
                            .monospacedDigit()
                            .foregroundStyle(MonitorDesign.inkPrimary)
                        Text(verbatim: "%")
                            .font(MonitorDesign.microFont(size: scale.hero * hubHeroScale * 0.42))
                            .foregroundStyle(MonitorDesign.inkFaint)
                    }
                    // "100%" is hub-width at the new ring sizes; shrink, not clip.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    Text(verbatim: "5H")
                        .font(MonitorDesign.labelFont(size: scale.label * 0.9))
                        .tracking(MonitorDesign.labelTracking(size: scale.label))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
            }
            // 76 pt is the vertical budget left in the fixed 170 pt S tile once
            // the week meter and today row take their share.
            .frame(width: 76, height: 76)
            Spacer(minLength: 0)
        }
    }

    /// Weekly quota micro-meter — used% + tiny days-aware reset, over a thin bar.
    private func weekMicroMeter(
        _ usage: MonitorUsageSnapshot, scale: MonitorDesign.TypeScale
    ) -> some View {
        QuotaMeter(
            name: "Week",
            fraction: usage.weekUsedPercent ?? 0,
            resetText: usage.weekResetsAt.map { Self.weekResetText(secondsRemaining: $0 - nowEpoch) },
            scale: scale,
            showResetPrefix: false
        )
    }

    /// today $ AND tokens (both, compact) + provider status dot pushed right.
    /// Both readouts are provider-scoped (`filteredCostTodayUSD`/
    /// `filteredTokensToday`); under `primaryMetric == "cost"` the tokens figure
    /// recedes an extra step (inkFaint instead of inkMuted).
    private func todayRowCompact(
        _ usage: MonitorUsageSnapshot, scale: MonitorDesign.TypeScale
    ) -> some View {
        let costLeads = Self.costLeads(primaryMetric)
        let cost = Self.filteredCostTodayUSD(usage, provider: provider)
        let tokens = Self.filteredTokensToday(usage, provider: provider)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("TODAY")
                .font(MonitorDesign.labelFont(size: scale.label))
                .tracking(MonitorDesign.labelTracking(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: MonitorFormat.usd(cost))
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let tokens {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: MonitorFormat.tokens(tokens.input + tokens.output))
                        .font(MonitorDesign.subFont(size: scale.caption))
                        .monospacedDigit()
                        .foregroundStyle(costLeads ? MonitorDesign.inkFaint : MonitorDesign.inkMuted)
                    Text(verbatim: "tok")
                        .font(MonitorDesign.microFont(size: scale.label * 0.86))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 4)
            let status = Self.providerStatus(usage)
            Circle()
                .fill(status.color)
                .frame(width: scale.label * 0.55, height: scale.label * 0.55)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                .shadow(color: status.color.opacity(0.6), radius: 3)
        }
    }

    // MARK: - M (364×170 — content ≈ 332×125)

    @ViewBuilder
    private func mediumBody(_ usage: MonitorUsageSnapshot, cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let hasQuota = Self.hasQuota(usage) && Self.quotaVisible(provider)
        HStack(alignment: .top, spacing: 14) {
            leftColumn(usage, scale: scale)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hasQuota {
                rightColumn(usage, scale: scale, cellHeight: cellHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// LEFT COLUMN: 5h ring hero + today $/tokens, provider split, cache row.
    /// Budget ≈ 159×125 pt: ring 60 + split (~20) + one-line cache (~16) + two
    /// hairline blocks — the L strip's separate bar/legend rows don't fit here.
    @ViewBuilder
    private func leftColumn(
        _ usage: MonitorUsageSnapshot, scale: MonitorDesign.TypeScale
    ) -> some View {
        let stale = Self.isLimitsStale(usage)
        VStack(alignment: .leading, spacing: scale.label * 0.5) {
            HStack(alignment: .center, spacing: 10) {
                if Self.hasQuota(usage) && Self.quotaVisible(provider) {
                    let pct = usage.fiveHourUsedPercent ?? 0
                    ArcGauge(value: pct, color: Self.quotaBandColor(pct)) {
                        VStack(spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(verbatim: Self.wholePercentValue(pct))
                                    .font(MonitorDesign.heroFont(size: scale.hero * 0.62))
                                    .monospacedDigit()
                                    .foregroundStyle(MonitorDesign.inkPrimary)
                                Text(verbatim: "%")
                                    .font(MonitorDesign.microFont(size: scale.hero * 0.28))
                                    .foregroundStyle(MonitorDesign.inkFaint)
                            }
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            Text(verbatim: "5H")
                                .font(MonitorDesign.labelFont(size: scale.label * 0.82))
                                .tracking(MonitorDesign.labelTracking(size: scale.label))
                                .foregroundStyle(MonitorDesign.inkFaint)
                        }
                    }
                    .frame(width: 60, height: 60)
                    .opacity(stale ? 0.5 : 1)
                }
                todayStack(usage, scale: scale)
            }
            // The Claude/Codex split is meaningless once scoped to one provider —
            // hidden alongside the other cross-provider aggregates (§ aggregatesVisible).
            if Self.aggregatesVisible(provider), let split = Self.providerSplit(usage) {
                hairline
                providerSplitBar(split, scale: scale)
            }
            if let tokens = Self.filteredTokensToday(usage, provider: provider), tokens != .zero {
                hairline
                cacheRowCompact(tokens, scale: scale)
            }
        }
    }

    /// M-only merged cache read: label · four-segment bar · hit% chip on ONE
    /// line. The segments stay legible unlabelled at this width; the labelled
    /// three-row strip remains an L luxury (`cacheStrip`).
    private func cacheRowCompact(
        _ tokens: MonitorTokenTotals, scale: MonitorDesign.TypeScale
    ) -> some View {
        let segments = Self.cacheSegments(tokens)
        return HStack(spacing: 8) {
            Text("CACHE")
                .font(MonitorDesign.labelFont(size: scale.label))
                .tracking(MonitorDesign.labelTracking(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
            CacheSegmentBar(segments: segments)
                .frame(height: max(4, scale.caption * 0.42))
                .frame(maxWidth: .infinity)
            if let hit = Self.cacheHitRate(tokens) {
                (Text(verbatim: "\(Self.wholePercent(hit)) ") + Text("hit"))
                    .font(MonitorDesign.subFont(size: scale.label))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.oklch(0.72, 0.08, 158))
                    .lineLimit(1)
                    .monitorChip(scale)
            }
        }
    }

    /// today $ + tokens as a two-line stat stack (mock's `.todayrow` column),
    /// provider-scoped; TOKENS recedes to inkFaint when cost leads.
    private func todayStack(
        _ usage: MonitorUsageSnapshot, scale: MonitorDesign.TypeScale
    ) -> some View {
        let costLeads = Self.costLeads(primaryMetric)
        return VStack(alignment: .leading, spacing: scale.label * 0.4) {
            statLine(key: String(localized: "TODAY $", comment: "Usage widget: today's spend label ($ is a currency glyph)."),
                     value: MonitorFormat.usd(Self.filteredCostTodayUSD(usage, provider: provider)), scale: scale)
            if let tokens = Self.filteredTokensToday(usage, provider: provider) {
                statLine(key: String(localized: "TOKENS", comment: "Usage widget: today's token-count label."),
                         value: MonitorFormat.tokens(tokens.input + tokens.output), scale: scale, muted: costLeads)
            }
        }
    }

    /// `muted` recedes the value to `inkFaint` — used for the non-primary metric
    /// when `primaryMetric == "cost"` (default `false` keeps every pre-existing
    /// call site's rendering unchanged).
    private func statLine(
        key: String, value: String, scale: MonitorDesign.TypeScale, muted: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: key)
                .font(MonitorDesign.labelFont(size: scale.label * 0.9))
                .tracking(MonitorDesign.labelTracking(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: value)
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(muted ? MonitorDesign.inkFaint : MonitorDesign.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// RIGHT COLUMN: 5h + week meters, burn-ETA chip, 7-day sparkline.
    @ViewBuilder
    private func rightColumn(
        _ usage: MonitorUsageSnapshot, scale: MonitorDesign.TypeScale, cellHeight: CGFloat
    ) -> some View {
        let stale = Self.isLimitsStale(usage)
        VStack(alignment: .leading, spacing: scale.label * 0.55) {
            Group {
                QuotaMeter(
                    name: "5H limit",
                    fraction: usage.fiveHourUsedPercent ?? 0,
                    resetText: usage.fiveHourResetsAt.map {
                        Self.fiveHourResetText(secondsRemaining: $0 - nowEpoch)
                    },
                    scale: scale,
                    showResetPrefix: true
                )
                QuotaMeter(
                    name: "Week",
                    fraction: usage.weekUsedPercent ?? 0,
                    resetText: usage.weekResetsAt.map {
                        Self.weekResetText(secondsRemaining: $0 - nowEpoch)
                    },
                    scale: scale,
                    showResetPrefix: true
                )
            }
            .opacity(stale ? 0.5 : 1)

            // Burn-rate ETA chip — ONLY when honestly derivable (§3.4). Also
            // suppressed while stale (a stale quota can't feed a live slope) or
            // provider-filtered (the slope isn't attributable to one provider).
            if Self.aggregatesVisible(provider), !stale, let eta = burnETA {
                burnETAChip(seconds: eta, scale: scale)
            }

            // 7-day mini sparkline of daily tokens — cross-provider (no per-day
            // provider split in the schema), so hidden under a provider filter.
            if Self.aggregatesVisible(provider), let week7 = Self.week7Tokens(usage) {
                week7Sparkline(week7, scale: scale)
            }
        }
    }

    private func burnETAChip(seconds: Double, scale: MonitorDesign.TypeScale) -> some View {
        let critical = Self.isETACritical(seconds)
        let accent = critical ? MonitorDesign.signalCoral : MonitorDesign.signalAmber
        return HStack(spacing: 6) {
            // The mock's teardrop `.burnicon` — a rotated rounded square; its
            // accent (coral when critical) now carries the near-limit escalation
            // that the old bespoke coral capsule used to.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent)
                .frame(width: scale.label * 0.55, height: scale.label * 0.55)
                .rotationEffect(.degrees(45))
            Text("TO 5H LIMIT")
                .font(MonitorDesign.labelFont(size: scale.label * 0.92))
                .tracking(MonitorDesign.labelTracking(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: "~\(MonitorFormat.countdown(seconds))")
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
        }
        .monitorChip(scale)
        .fixedSize()
    }

    private func week7Sparkline(_ week7: [Double], scale: MonitorDesign.TypeScale) -> some View {
        VStack(alignment: .leading, spacing: scale.label * 0.3) {
            HStack(alignment: .firstTextBaseline) {
                Text("7-DAY TOKENS")
                    .font(MonitorDesign.labelFont(size: scale.label * 0.9))
                    .tracking(MonitorDesign.labelTracking(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if let today = week7.last {
                    // Token count is data (verbatim); "today" reuses the localized
                    // TODAY key, lowercased for this inline caption.
                    (Text(verbatim: "\(MonitorFormat.tokens(Int(today))) ")
                     + Text(verbatim: String(localized: "TODAY").lowercased()))
                        .font(MonitorDesign.captionFont(size: scale.label))
                        .monospacedDigit()
                        .foregroundStyle(MonitorDesign.inkFaint)
                        .lineLimit(1)
                        .monitorChip(scale)
                }
            }
            Week7Bars(values: week7)
                .frame(maxWidth: .infinity, minHeight: 20)
                .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - L (364×376 — content ≈ 332×331) — the "ledger-lite" glance panel

    /// L is a taller instrument stack that surfaces the two things M has no room
    /// for: the client burn-rate readouts and the per-model breakdown (both come
    /// straight from `MonitorUsageSnapshot`, never re-sampled). Zone order echoes
    /// the Usage Ledger (§3.2.8) while staying quota-forward: hero ring + summary →
    /// 5h/week meters + burn-ETA → per-model share → cache + 7-day trend. Every
    /// zone degrades independently (no quota / no models / no cache each drop out).
    @ViewBuilder
    private func largeBody(_ usage: MonitorUsageSnapshot, cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let stale = Self.isLimitsStale(usage)
        let hasQuota = Self.hasQuota(usage) && Self.quotaVisible(provider)
        let showsTrend = Self.aggregatesVisible(provider) && Self.week7Tokens(usage) != nil
        VStack(alignment: .leading, spacing: scale.label * 0.72) {
            largeHeroRow(usage, scale: scale, stale: stale, hasQuota: hasQuota)

            if hasQuota {
                hairline
                largeQuotaRow(usage, scale: scale, stale: stale)
            }

            if let models = Self.topModels(usage, provider: provider) {
                hairline
                perModelSection(models, scale: scale)
            }

            if Self.hasCache(usage, provider: provider) || showsTrend {
                hairline
                largeFootRow(usage, scale: scale)
            }

            // Staleness reads from the header pill + the dimmed quota block (as in
            // M); no extra bottom marker so the panel doesn't repeat itself.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Hero: the 5h ring beside a 2×2 stat grid — today $/tokens + burn $/tok per
    /// hour. The burn cells only appear when the rate is honestly derived.
    private func largeHeroRow(
        _ usage: MonitorUsageSnapshot, scale: MonitorDesign.TypeScale, stale: Bool, hasQuota: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            if hasQuota {
                let pct = usage.fiveHourUsedPercent ?? 0
                ArcGauge(value: pct, color: Self.quotaBandColor(pct)) {
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(verbatim: Self.wholePercentValue(pct))
                                .font(MonitorDesign.heroFont(size: scale.hero * 0.66))
                                .monospacedDigit()
                                .foregroundStyle(MonitorDesign.inkPrimary)
                            Text(verbatim: "%")
                                .font(MonitorDesign.microFont(size: scale.hero * 0.3))
                                .foregroundStyle(MonitorDesign.inkFaint)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        Text(verbatim: "5H")
                            .font(MonitorDesign.labelFont(size: scale.label * 0.86))
                            .tracking(MonitorDesign.labelTracking(size: scale.label))
                            .foregroundStyle(MonitorDesign.inkFaint)
                    }
                }
                .frame(width: 92, height: 92)
                .opacity(stale ? 0.5 : 1)
            }
            largeSummaryGrid(usage, scale: scale)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A 2×2 grid of quiet readouts (the ledger's summary strip, condensed):
    /// TODAY $ · TOKENS on the first row (provider-scoped; TOKENS recedes when
    /// cost leads), BURN $/h · BURN tok/h on the second (cross-provider, so
    /// hidden under a provider filter — the burn window has no per-provider
    /// attribution in the schema).
    @ViewBuilder
    private func largeSummaryGrid(
        _ usage: MonitorUsageSnapshot, scale: MonitorDesign.TypeScale
    ) -> some View {
        let cost = usage.costBurnRatePerHour
        let tok = usage.tokenBurnRatePerHour
        let costLeads = Self.costLeads(primaryMetric)
        VStack(alignment: .leading, spacing: scale.label * 0.55) {
            HStack(alignment: .top, spacing: 14) {
                statLine(key: String(localized: "TODAY $", comment: "Usage widget: today's spend label ($ is a currency glyph)."),
                         value: MonitorFormat.usd(Self.filteredCostTodayUSD(usage, provider: provider)), scale: scale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let tokens = Self.filteredTokensToday(usage, provider: provider) {
                    statLine(key: String(localized: "TOKENS", comment: "Usage widget: today's token-count label."),
                             value: MonitorFormat.tokens(tokens.input + tokens.output), scale: scale, muted: costLeads)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if Self.aggregatesVisible(provider), cost != nil || tok != nil {
                HStack(alignment: .top, spacing: 14) {
                    burnStatLine(
                        key: String(localized: "BURN $/h", comment: "Usage widget: cost burned per hour label ($/h is a rate unit)."),
                        value: cost.map { "\(MonitorFormat.usd($0))/h" },
                        scale: scale
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    burnStatLine(
                        key: String(localized: "BURN tok/h", comment: "Usage widget: tokens burned per hour label (tok/h is a rate unit)."),
                        value: tok.map { "\(MonitorFormat.tokens(Int($0)))/h" },
                        scale: scale
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// A summary cell whose value is the free local tail (verbatim), dimmed to a
    /// dash when the rate isn't honestly derivable yet.
    private func burnStatLine(
        key: String, value: String?, scale: MonitorDesign.TypeScale
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: key)
                .font(MonitorDesign.labelFont(size: scale.label * 0.9))
                .tracking(MonitorDesign.labelTracking(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: value ?? "—")
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(value == nil ? MonitorDesign.inkFaint : MonitorDesign.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 5h + week meters side by side, then the burn-ETA chip (honest-only).
    @ViewBuilder
    private func largeQuotaRow(
        _ usage: MonitorUsageSnapshot, scale: MonitorDesign.TypeScale, stale: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: scale.label * 0.6) {
            HStack(alignment: .top, spacing: 16) {
                QuotaMeter(
                    name: "5H limit",
                    fraction: usage.fiveHourUsedPercent ?? 0,
                    resetText: usage.fiveHourResetsAt.map {
                        Self.fiveHourResetText(secondsRemaining: $0 - nowEpoch)
                    },
                    scale: scale,
                    showResetPrefix: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                QuotaMeter(
                    name: "Week",
                    fraction: usage.weekUsedPercent ?? 0,
                    resetText: usage.weekResetsAt.map {
                        Self.weekResetText(secondsRemaining: $0 - nowEpoch)
                    },
                    scale: scale,
                    showResetPrefix: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(stale ? 0.5 : 1)

            if Self.aggregatesVisible(provider), !stale, let eta = burnETA {
                burnETAChip(seconds: eta, scale: scale)
            }
        }
    }

    /// Per-model breakdown — the one thing M can't fit: a stacked share bar over a
    /// compact valued list (model-id · tokens · cost · share bar). Model-ids only
    /// (privacy-safe); costs are nil for unpriced models and render as a dash.
    private func perModelSection(
        _ models: [MonitorUsageModelBreakdown], scale: MonitorDesign.TypeScale
    ) -> some View {
        let total = models.reduce(0) { $0 + Self.modelTokens($1) }
        return VStack(alignment: .leading, spacing: scale.label * 0.5) {
            HStack(alignment: .firstTextBaseline) {
                Text("PER-MODEL")
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(MonitorDesign.labelTracking(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
                Spacer(minLength: 4)
                Text(verbatim: MonitorFormat.tokens(total))
                    .font(MonitorDesign.captionFont(size: scale.label))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkFaint)
            }
            ModelShareBar(models: models, total: total)
                .frame(height: max(6, scale.caption * 0.7))
            VStack(alignment: .leading, spacing: scale.label * 0.42) {
                ForEach(models, id: \.model) { model in
                    modelRow(model, total: total, scale: scale)
                }
            }
        }
    }

    /// Under `primaryMetric == "cost"` the cost/tokens cells swap places (cost
    /// leads) and tokens recedes to `inkMuted`→`inkFaint`; default order/tone is
    /// untouched. Cost is always `MonitorFormat.usd(nil)` → "—" for unpriced
    /// models (never fabricated).
    private func modelRow(
        _ model: MonitorUsageModelBreakdown, total: Int, scale: MonitorDesign.TypeScale
    ) -> some View {
        let tokens = Self.modelTokens(model)
        let share = total > 0 ? Double(tokens) / Double(total) : 0
        let costLeads = Self.costLeads(primaryMetric)
        let tokensCell = Text(verbatim: MonitorFormat.tokens(tokens))
            .font(MonitorDesign.subFont(size: scale.label))
            .monospacedDigit()
            .foregroundStyle(costLeads ? MonitorDesign.inkFaint : MonitorDesign.inkMuted)
            .frame(minWidth: scale.caption * 2.6, alignment: .trailing)
        let costCell = Text(verbatim: MonitorFormat.usd(model.costUSD))
            .font(MonitorDesign.subFont(size: scale.label))
            .monospacedDigit()
            .foregroundStyle(model.costUSD == nil ? MonitorDesign.inkFaint : MonitorDesign.inkPrimary)
            .frame(minWidth: scale.caption * 2.6, alignment: .trailing)
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Self.modelColor(model.model))
                .frame(width: scale.label * 0.6, height: scale.label * 0.6)
            Text(verbatim: Self.modelShortName(model.model))
                .font(MonitorDesign.captionFont(size: scale.caption))
                .foregroundStyle(MonitorDesign.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            Text(verbatim: Self.wholePercent(share))
                .font(MonitorDesign.captionFont(size: scale.label))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkFaint)
            if costLeads {
                costCell
                tokensCell
            } else {
                tokensCell
                costCell
            }
        }
    }

    /// Bottom two-up: cache four-segment strip (left) + 7-day token trend (right).
    /// Each half is optional, so a no-cache or no-history snapshot keeps the other.
    @ViewBuilder
    private func largeFootRow(
        _ usage: MonitorUsageSnapshot, scale: MonitorDesign.TypeScale
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if let tokens = Self.filteredTokensToday(usage, provider: provider), tokens != .zero {
                cacheStrip(tokens, scale: scale)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if Self.aggregatesVisible(provider), let week7 = Self.week7Tokens(usage) {
                week7Sparkline(week7, scale: scale)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Cache four-segment strip (L; M uses `cacheRowCompact`)

    private func cacheStrip(
        _ tokens: MonitorTokenTotals, scale: MonitorDesign.TypeScale
    ) -> some View {
        let segments = Self.cacheSegments(tokens)
        return VStack(alignment: .leading, spacing: scale.label * 0.35) {
            HStack(alignment: .firstTextBaseline) {
                Text("CACHE")
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(MonitorDesign.labelTracking(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
                Spacer(minLength: 4)
                if let hit = Self.cacheHitRate(tokens) {
                    // The percentage is data (verbatim); "hit" is a word (localized).
                    (Text(verbatim: "\(Self.wholePercent(hit)) ") + Text("hit"))
                        .font(MonitorDesign.subFont(size: scale.label))
                        .monospacedDigit()
                        .foregroundStyle(MonitorDesign.oklch(0.72, 0.08, 158))
                        .monitorChip(scale)
                }
            }
            CacheSegmentBar(segments: segments)
                .frame(height: max(4, scale.caption * 0.42))
            HStack(spacing: 9) {
                ForEach(segments) { seg in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(seg.kind.legendColor)
                            .frame(width: scale.label * 0.5, height: scale.label * 0.5)
                        Text(verbatim: seg.kind.legendLabel)
                            .font(MonitorDesign.captionFont(size: scale.label * 0.9))
                            .foregroundStyle(MonitorDesign.inkFaint)
                    }
                }
            }
        }
    }

    // MARK: - Provider split bar

    private func providerSplitBar(
        _ split: ProviderSplit, scale: MonitorDesign.TypeScale
    ) -> some View {
        VStack(alignment: .leading, spacing: scale.label * 0.4) {
            GeometryReader { g in
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [MonitorDesign.oklch(0.62, 0.03, 80), MonitorDesign.oklch(0.72, 0.05, 82)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: max(0, g.size.width * CGFloat(split.claudeShare)))
                    LinearGradient(
                        colors: [MonitorDesign.oklch(0.5, 0.014, 250), MonitorDesign.oklch(0.6, 0.03, 246)],
                        startPoint: .leading, endPoint: .trailing
                    )
                }
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Color.white.opacity(0.14), .clear],
                                   startPoint: .top, endPoint: .center)
                }
            }
            .frame(height: max(4, scale.caption * 0.5))
            .clipShape(Capsule())
            HStack(spacing: 14) {
                providerLegendItem(
                    color: MonitorDesign.oklch(0.7, 0.05, 82), name: "Claude",
                    value: MonitorFormat.usd(split.claudeCost), scale: scale)
                providerLegendItem(
                    color: MonitorDesign.oklch(0.58, 0.03, 246), name: "Codex",
                    value: MonitorFormat.usd(split.codexCost), scale: scale)
            }
        }
    }

    private func providerLegendItem(
        color: Color, name: String, value: String, scale: MonitorDesign.TypeScale
    ) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: scale.label * 0.55, height: scale.label * 0.55)
            Text(verbatim: name)
                .font(MonitorDesign.captionFont(size: scale.label))
                .foregroundStyle(MonitorDesign.inkMuted)
            Text(verbatim: value)
                .font(MonitorDesign.subFont(size: scale.label))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
        }
    }

    // MARK: - Shared chrome

    private var hairline: some View {
        Rectangle()
            .fill(MonitorDesign.hairline.opacity(0.45))
            .frame(height: MonitorDesign.hairlineWidth)
    }

    /// Quiet setup-needed state when `usage == nil` (module off / no source yet).
    /// A missing folder grant (runtime-synthesized `unauthorized` health) names
    /// the real fix instead of implying data will arrive on its own.
    private func setupNeeded(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let unauthorized = (context.snapshot.health ?? []).contains {
            ($0.sourceID == "claude" || $0.sourceID == "codex") && $0.state == "unauthorized"
        }
        return VStack(alignment: .leading, spacing: scale.label * 0.5) {
            Spacer(minLength: 0)
            Image(systemName: unauthorized ? "folder.badge.questionmark" : "gauge.with.dots.needle.bottom.0percent")
                .font(.system(size: scale.hero * 0.5, weight: .regular))
                .foregroundStyle(unauthorized ? MonitorDesign.signalAmber : MonitorDesign.inkFaint)
            Text("No usage yet")
                .font(MonitorDesign.subFont(size: scale.caption))
                .foregroundStyle(MonitorDesign.inkMuted)
            Group {
                if unauthorized {
                    Text("Authorize the agent folders in Monitor settings.")
                } else if context.placement.size == .small {
                    Text("Run an agent to track tokens.")
                } else {
                    Text("Session token & cost tracking starts automatically once an agent runs.")
                }
            }
                .font(MonitorDesign.captionFont(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Derived (instance)

    /// Client-derived ETA (seconds) to the 5h cap from the sparse used% history.
    private var burnETA: Double? {
        Self.burnETASeconds(times: history.usageQuotaTimes, used: history.usageFiveHourUsed)
    }

    // MARK: - Pure helpers (nonisolated for tests)

    /// Escalation bands. The near-limit DOT (`quotaBand`) uses `warm`/`crit`; the
    /// hotter bar-FILL scale (`quotaFill`) uses `warn`/`crit`. Ported from the
    /// mock's two separate thresholds (p is 0-100 there; here 0…1).
    enum Band { case normal, warm, warn, crit }

    nonisolated static func quotaBand(_ fraction: Double) -> Band {
        let f = clampUnit(fraction)
        if f > 0.85 { return .crit }
        if f >= 0.40 { return .warm }
        return .normal
    }

    /// Bar-fill escalation — a hotter scale than the dot (mock `quotaFill(p)`):
    /// warn >75%, crit >90%.
    nonisolated static func quotaFill(_ fraction: Double) -> Band {
        let f = clampUnit(fraction)
        if f > 0.90 { return .crit }
        if f > 0.75 { return .warn }
        return .normal
    }

    /// Ring/hero colour: reuse the shared load-band steel/amber, but escalate to
    /// coral in the near-limit `crit` band (mirrors the mock's ring treatment).
    nonisolated static func quotaBandColor(_ fraction: Double) -> Color {
        switch quotaBand(fraction) {
        case .normal: return MonitorDesign.loadSteel
        case .warm, .warn: return MonitorDesign.signalAmber
        case .crit: return MonitorDesign.signalCoral
        }
    }

    /// The colour a quota bar fill uses at a given used% (the hotter scale).
    nonisolated static func quotaFillColor(_ fraction: Double) -> Color {
        switch quotaFill(fraction) {
        case .normal: return MonitorDesign.signalSteel
        case .warm, .warn: return MonitorDesign.signalAmber
        case .crit: return MonitorDesign.signalCoral
        }
    }

    /// ETA is "critical" (coral chip) at ≤15 min, matching mock `etaCrit`.
    nonisolated static func isETACritical(_ seconds: Double) -> Bool {
        seconds <= 15 * 60
    }

    /// Whole-percent string from a 0…1 fraction ("58%").
    nonisolated static func wholePercent(_ fraction: Double) -> String {
        "\(wholePercentValue(fraction))%"
    }

    /// Numeric portion used when the percent glyph has its own visual style.
    nonisolated static func wholePercentValue(_ fraction: Double) -> String {
        "\(Int((clampUnit(fraction) * 100).rounded()))"
    }

    /// True when `limitsStale == true` (nil / false both mean fresh).
    nonisolated static func isLimitsStale(_ usage: MonitorUsageSnapshot) -> Bool {
        usage.limitsStale == true
    }

    /// Quota blocks render only when the 5h field exists (statusline installed).
    nonisolated static func hasQuota(_ usage: MonitorUsageSnapshot) -> Bool {
        usage.fiveHourUsedPercent != nil
    }

    // MARK: - Settings read side (`provider` / `primaryMetric`)
    //
    // Both options are `.string`; an absent or unrecognised raw value falls back
    // to the documented default so a stale/mistyped popover write can't corrupt
    // the read side. Every filtering helper below composes on top of these two.

    /// `provider` raw string ⇒ resolved filter. Anything but "claude"/"codex"
    /// (including nil/absent) ⇒ "all" — no filtering, today's behaviour.
    nonisolated static func resolvedProvider(_ raw: String?) -> String {
        switch raw {
        case "claude", "codex": return raw!
        default: return "all"
        }
    }

    /// `primaryMetric` raw string ⇒ resolved metric. Anything but "cost"
    /// (including nil/absent) ⇒ "tokens" — the pre-existing rendering.
    nonisolated static func resolvedPrimaryMetric(_ raw: String?) -> String {
        raw == "cost" ? "cost" : "tokens"
    }

    /// Whether cost should visually lead over tokens (hero summary + per-model
    /// rows) — true only for the explicit "cost" setting.
    nonisolated static func costLeads(_ primaryMetric: String) -> Bool {
        primaryMetric == "cost"
    }

    /// Quota (5h/week %, resets, burn-ETA) is Claude-only data (§3.4 — sourced
    /// from the statusline rate-limit capture, which has no Codex equivalent).
    /// Visible under "all"/"claude"; honestly hidden under "codex" rather than
    /// showing a Claude limit mislabeled as Codex's.
    nonisolated static func quotaVisible(_ provider: String) -> Bool {
        provider != "codex"
    }

    /// Cross-provider aggregates with no per-provider attribution anywhere in
    /// the schema — the burn-rate window, the 7-day trend (`dailyActivity` has
    /// no per-model/provider split), and the Claude/Codex split bar itself
    /// (meaningless once already scoped to one provider). Shown only under
    /// "all" so a single-provider view never silently blends in the other
    /// provider's numbers under a readout that looks scoped.
    nonisolated static func aggregatesVisible(_ provider: String) -> Bool {
        provider == "all"
    }

    /// Today's cost, scoped to `provider`. Codex has no public per-token rate
    /// (`MonitorTokenPricing`), so `perProvider["codex"].costTodayUSD` is always
    /// nil — filtering surfaces that honestly (`MonitorFormat.usd(nil)` → "—"),
    /// never a fabricated figure.
    nonisolated static func filteredCostTodayUSD(
        _ usage: MonitorUsageSnapshot, provider: String
    ) -> Double? {
        provider == "all" ? usage.costTodayUSD : usage.perProvider?[provider]?.costTodayUSD
    }

    /// Today's token totals, scoped to `provider`.
    nonisolated static func filteredTokensToday(
        _ usage: MonitorUsageSnapshot, provider: String
    ) -> MonitorTokenTotals? {
        provider == "all" ? usage.tokensToday : usage.perProvider?[provider]?.tokensToday
    }

    /// Provider inferred from a model-id, for per-model filtering: Claude always
    /// prefixes "claude-"; every other id in `perModel` (gpt-5*, the Codex
    /// fallback literal "codex", …) is Codex-origin — `MonitorUsageLedgerFragment`
    /// only ever merges these two sources.
    nonisolated static func modelProvider(_ model: String) -> String {
        model.lowercased().hasPrefix("claude") ? "claude" : "codex"
    }

    /// `perModel`, scoped to `provider`; nil when absent, empty, or nothing
    /// matches the filter (same "absent" contract as the unfiltered field).
    nonisolated static func filteredPerModel(
        _ usage: MonitorUsageSnapshot, provider: String
    ) -> [MonitorUsageModelBreakdown]? {
        guard let models = usage.perModel, !models.isEmpty else { return nil }
        guard provider != "all" else { return models }
        let filtered = models.filter { modelProvider($0.model) == provider }
        return filtered.isEmpty ? nil : filtered
    }

    nonisolated static func fiveHourResetText(secondsRemaining: Double) -> String {
        MonitorFormat.countdown(secondsRemaining)
    }

    nonisolated static func weekResetText(secondsRemaining: Double) -> String {
        MonitorFormat.countdownDays(secondsRemaining)
    }

    /// Least-squares (fallback two-point) slope of used% over time → seconds until
    /// the series reaches 1.0. Honest-only: needs ≥2 samples and a POSITIVE slope;
    /// nil otherwise. Already-capped returns 0. The raw ETA is clamped so a
    /// whisper-slow slope can't produce an absurd horizon.
    nonisolated static func burnETASeconds(times: [Double], used: [Double]) -> Double? {
        guard times.count == used.count, used.count >= 2 else { return nil }
        guard let last = used.last, let lastTime = times.last else { return nil }
        let currentUsed = clampUnit(last)
        if currentUsed >= 1.0 { return 0 }

        let n = Double(used.count)
        let sumT = times.reduce(0, +)
        let sumU = used.reduce(0, +)
        let meanT = sumT / n
        let meanU = sumU / n
        var num = 0.0, den = 0.0
        for i in 0..<used.count {
            let dt = times[i] - meanT
            num += dt * (used[i] - meanU)
            den += dt * dt
        }
        // Degenerate time axis (all-equal timestamps) → no usable slope.
        guard den > 0 else { return nil }
        let slopePerSecond = num / den
        guard slopePerSecond > 0 else { return nil }

        let remaining = 1.0 - currentUsed
        let rawETA = remaining / slopePerSecond
        guard rawETA.isFinite, rawETA >= 0 else { return nil }
        // Anchor "now" at the last sample; the widget's countdown is relative.
        _ = lastTime
        return min(rawETA, burnETAClampSeconds)
    }

    /// ETA horizon cap — a slope slower than this reads as "not meaningfully
    /// approaching the cap"; we still show the (clamped) figure rather than lie.
    nonisolated static let burnETAClampSeconds: Double = 24 * 3600

    /// Four cache segments (input / output / cacheRead / cacheWrite) as fractions
    /// of their sum — the same `MonitorTokenTotals` fields, a free four-part strip.
    nonisolated static func cacheSegments(_ tokens: MonitorTokenTotals) -> [CacheSegment] {
        let total = Double(tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite)
        func frac(_ v: Int) -> Double { total > 0 ? Double(v) / total : 0 }
        return [
            CacheSegment(kind: .input, fraction: frac(tokens.input)),
            CacheSegment(kind: .output, fraction: frac(tokens.output)),
            CacheSegment(kind: .cacheRead, fraction: frac(tokens.cacheRead)),
            CacheSegment(kind: .cacheWrite, fraction: frac(tokens.cacheWrite))
        ]
    }

    /// cacheRead / (input + cacheRead) — nil when there were no reads at all.
    nonisolated static func cacheHitRate(_ tokens: MonitorTokenTotals) -> Double? {
        let denom = tokens.input + tokens.cacheRead
        guard denom > 0 else { return nil }
        return Double(tokens.cacheRead) / Double(denom)
    }

    /// Provider cost split from `perProvider`; nil when both providers are absent.
    nonisolated static func providerSplit(_ usage: MonitorUsageSnapshot) -> ProviderSplit? {
        guard let per = usage.perProvider else { return nil }
        let claude = per["claude"]?.costTodayUSD ?? 0
        let codex = per["codex"]?.costTodayUSD ?? 0
        guard claude > 0 || codex > 0 else { return nil }
        return ProviderSplit(claudeCost: claude, codexCost: codex)
    }

    /// Last 7 daily token buckets (input+output), oldest→today; nil when no daily
    /// activity exists. Honest empty days stay flat (a zero bucket).
    nonisolated static func week7Tokens(_ usage: MonitorUsageSnapshot) -> [Double]? {
        guard let daily = usage.dailyActivity, !daily.isEmpty else { return nil }
        let last7 = daily.suffix(7)
        return last7.map { Double($0.tokens.input + $0.tokens.output) }
    }

    /// True when today's token totals carry any cache traffic worth a strip.
    nonisolated static func hasCache(_ usage: MonitorUsageSnapshot) -> Bool {
        guard let t = usage.tokensToday else { return false }
        return t != .zero
    }

    /// `hasCache`, scoped to `provider` via `filteredTokensToday`.
    nonisolated static func hasCache(_ usage: MonitorUsageSnapshot, provider: String) -> Bool {
        guard let t = filteredTokensToday(usage, provider: provider) else { return false }
        return t != .zero
    }

    /// Total tokens across the four buckets for one model breakdown.
    nonisolated static func modelTokens(_ model: MonitorUsageModelBreakdown) -> Int {
        model.tokens.input + model.tokens.output + model.tokens.cacheRead + model.tokens.cacheWrite
    }

    /// The top `limit` models by token volume (already sorted descending by the
    /// rollup), optionally scoped to `provider`; nil when the (filtered)
    /// breakdown is absent or empty. L shows the busiest few rather than every
    /// model so the list stays scannable.
    nonisolated static func topModels(
        _ usage: MonitorUsageSnapshot, limit: Int = 4, provider: String = "all"
    ) -> [MonitorUsageModelBreakdown]? {
        guard let models = filteredPerModel(usage, provider: provider) else { return nil }
        return Array(models.prefix(max(1, limit)))
    }

    /// Coarse model family from a raw model-id — drives the per-model swatch hue
    /// and short label. Prefix-matched like `MonitorTokenPricing`, so unfamiliar
    /// ids fall through to `.other` (neutral) rather than mis-colouring.
    enum ModelFamily { case opus, sonnet, haiku, gpt5, gpt5mini, other }

    nonisolated static func modelFamily(_ model: String) -> ModelFamily {
        let id = model.lowercased()
        if id.contains("opus") { return .opus }
        if id.contains("sonnet") { return .sonnet }
        if id.contains("haiku") { return .haiku }
        if id.contains("gpt-5-mini") || id.contains("gpt-5m") || id.contains("mini") { return .gpt5mini }
        if id.contains("gpt-5") || id.contains("gpt5") || id.hasPrefix("gpt") { return .gpt5 }
        return .other
    }

    /// Per-model swatch colour — the ledger's harmonious warm hues (`--m-*`), all
    /// sitting on the graphite so the list never reads as a rainbow.
    nonisolated static func modelColor(_ model: String) -> Color {
        switch modelFamily(model) {
        case .opus: return MonitorDesign.oklch(0.72, 0.13, 78)
        case .sonnet: return MonitorDesign.oklch(0.66, 0.10, 55)
        case .haiku: return MonitorDesign.oklch(0.62, 0.055, 150)
        case .gpt5: return MonitorDesign.oklch(0.60, 0.085, 30)
        case .gpt5mini: return MonitorDesign.oklch(0.56, 0.045, 300)
        case .other: return MonitorDesign.loadSteel
        }
    }

    /// Concise display label for a model-id (privacy: model-ids are allowed). Known
    /// families collapse to a friendly token; anything else keeps the raw id with a
    /// trailing date/build suffix trimmed so the row stays short.
    nonisolated static func modelShortName(_ model: String) -> String {
        switch modelFamily(model) {
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        case .gpt5: return "GPT-5"
        case .gpt5mini: return "GPT-5 mini"
        case .other:
            // Drop a trailing "-<digits>" build/date stamp; cap length.
            var name = model
            if let range = name.range(of: "-[0-9]{4,}$", options: .regularExpression) {
                name.removeSubrange(range)
            }
            return name.count > 16 ? String(name.prefix(15)) + "…" : name
        }
    }

    struct StatusStyle { var color: Color; var label: String }

    nonisolated static func providerStatus(_ usage: MonitorUsageSnapshot) -> StatusStyle {
        if isLimitsStale(usage) {
            return StatusStyle(color: MonitorDesign.signalAmber,
                               label: String(localized: "stale", comment: "Usage widget: the quota/limit data is stale."))
        }
        return StatusStyle(color: MonitorDesign.signalSage,
                           label: String(localized: "live", comment: "Usage widget: the usage data is live/fresh."))
    }

    private nonisolated static func clampUnit(_ x: Double) -> Double {
        x.isFinite ? min(1, max(0, x)) : 0
    }

    // MARK: - Value types

    struct ProviderSplit: Equatable {
        var claudeCost: Double
        var codexCost: Double
        /// Claude's share of total cost (0…1); 0.5 when both are zero.
        var claudeShare: Double {
            let total = claudeCost + codexCost
            return total > 0 ? claudeCost / total : 0.5
        }
    }

    struct CacheSegment: Identifiable, Equatable {
        enum Kind: String, CaseIterable {
            case input, output, cacheRead, cacheWrite

            /// Legend abbreviations from the mock's `.cacheleg` (in/out/c-r/c-w).
            var legendLabel: String {
                switch self {
                case .input: return "in"
                case .output: return "out"
                case .cacheRead: return "c-r"
                case .cacheWrite: return "c-w"
                }
            }

            /// Bar/legend tone from `.cstrip .cs.*` — steel/teal in, sage cache.
            var barColor: Color {
                switch self {
                case .input: return MonitorDesign.oklch(0.56, 0.04, 250)
                case .output: return MonitorDesign.oklch(0.60, 0.05, 200)
                case .cacheRead: return MonitorDesign.oklch(0.62, 0.08, 158)
                case .cacheWrite: return MonitorDesign.oklch(0.50, 0.05, 158, alpha: 0.6)
                }
            }

            var legendColor: Color { barColor }
        }

        var kind: Kind
        var fraction: Double
        var id: String { kind.rawValue }
    }
}

// MARK: - QuotaMeter (one labelled meter: NAME · used% · reset, then a thin bar)

/// Ported from the mock's `qmeter`: the density comes from repetition + alignment.
/// Several stack with identical rhythm. Bar fill escalates warn→crit per used%.
private struct QuotaMeter: View {
    var name: String
    var fraction: Double
    var resetText: String?
    var scale: MonitorDesign.TypeScale
    var showResetPrefix: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: scale.label * 0.32) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Meter name ("Week" / "5H limit") — localized via its catalog key,
                // uppercased for display (a no-op for non-Latin scripts).
                Text(LocalizedStringKey(name))
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(MonitorDesign.labelTracking(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
                    .textCase(.uppercase)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(verbatim: "\(Int((clamped * 100).rounded()))")
                        .font(MonitorDesign.subFont(size: scale.caption))
                        .monospacedDigit()
                        .foregroundStyle(usedColor)
                    Text(verbatim: "%")
                        .font(MonitorDesign.microFont(size: scale.label * 0.86))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
                Spacer(minLength: 4)
                if let resetText {
                    // "resets" is a word (localized); the countdown is data (verbatim).
                    (showResetPrefix
                        ? Text("resets") + Text(verbatim: " \(resetText)")
                        : Text(verbatim: resetText))
                        .font(MonitorDesign.captionFont(size: scale.label))
                        .monospacedDigit()
                        .foregroundStyle(MonitorDesign.inkFaint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(MonitorDesign.track)
                    Capsule()
                        .fill(fillGradient)
                        .frame(width: max(0, g.size.width * CGFloat(clamped)))
                        .overlay(alignment: .top) {
                            LinearGradient(colors: [Color.white.opacity(0.16), .clear],
                                           startPoint: .top, endPoint: .center)
                                .clipShape(Capsule())
                                .frame(width: max(0, g.size.width * CGFloat(clamped)))
                        }
                }
            }
            .frame(height: max(4, scale.caption * 0.44))
        }
    }

    private var clamped: Double { fraction.isFinite ? min(1, max(0, fraction)) : 0 }

    private var usedColor: Color {
        switch MonitorUsageWidgetView.quotaFill(fraction) {
        case .normal: return MonitorDesign.inkPrimary
        case .warm, .warn: return MonitorDesign.oklch(0.86, 0.09, 44)
        case .crit: return MonitorDesign.oklch(0.90, 0.07, 38)
        }
    }

    private var fillGradient: LinearGradient {
        switch MonitorUsageWidgetView.quotaFill(fraction) {
        case .normal:
            return LinearGradient(
                colors: [MonitorDesign.signalSteel, MonitorDesign.oklch(0.66, 0.06, 210)],
                startPoint: .leading, endPoint: .trailing)
        case .warm, .warn:
            return LinearGradient(
                colors: [MonitorDesign.signalAmber, MonitorDesign.oklch(0.72, 0.15, 40)],
                startPoint: .leading, endPoint: .trailing)
        case .crit:
            return LinearGradient(
                colors: [MonitorDesign.oklch(0.72, 0.15, 40), MonitorDesign.signalCoral],
                startPoint: .leading, endPoint: .trailing)
        }
    }
}

// MARK: - CacheSegmentBar (four-part proportional strip)

private struct CacheSegmentBar: View {
    var segments: [MonitorUsageWidgetView.CacheSegment]

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(segments) { seg in
                    if seg.fraction > 0 {
                        seg.kind.barColor
                            .frame(width: max(1, g.size.width * CGFloat(seg.fraction)))
                            .overlay(alignment: .leading) {
                                Rectangle().fill(MonitorDesign.bg0.opacity(0.55)).frame(width: 1)
                            }
                    }
                }
            }
        }
        .background(MonitorDesign.track)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

// MARK: - Week7Bars (7-day daily-token mini bars + connecting polyline)

/// Ported from the mock's `wk7Spark`: per-day bars with today highlighted, framed
/// by a thin connecting polyline across the bar tops. Honest empty days sit flat.
private struct Week7Bars: View {
    var values: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = max(values.count, 1)
            let mx = max((values.max() ?? 0) * 1.12, .ulpOfOne)
            let bw = w / CGFloat(n)
            let gap = bw * 0.34
            let iw = max(1, bw - gap)
            ZStack {
                Rectangle()
                    .fill(MonitorDesign.hairline.opacity(0.45))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)

                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    let barH = max(1, CGFloat(min(1, v / mx)) * (h - 3))
                    let x = CGFloat(i) * bw + gap / 2
                    let today = i == values.count - 1
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(today ? MonitorDesign.oklch(0.82, 0.09, 78)
                                    : MonitorDesign.oklch(0.5, 0.028, 78))
                        .opacity(today ? 1 : 0.8)
                        .frame(width: iw, height: barH)
                        .position(x: x + iw / 2, y: h - barH / 2)
                }

                if values.count >= 2 {
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let barH = max(1, CGFloat(min(1, v / mx)) * (h - 3))
                            let x = CGFloat(i) * bw + gap / 2 + iw / 2
                            let y = h - barH
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                            else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(MonitorDesign.oklch(0.7, 0.05, 78, alpha: 0.55),
                            style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: - ModelShareBar (per-model token share, one segment per model)

/// The Ledger's `.mstack` share bar, condensed: each model contributes a segment
/// proportional to its token share, coloured by family. A thin dark seam keeps
/// adjacent segments legible.
private struct ModelShareBar: View {
    var models: [MonitorUsageModelBreakdown]
    var total: Int

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(models, id: \.model) { model in
                    let share = total > 0 ? Double(MonitorUsageWidgetView.modelTokens(model)) / Double(total) : 0
                    if share > 0 {
                        MonitorUsageWidgetView.modelColor(model.model)
                            .frame(width: max(1, g.size.width * CGFloat(share)))
                            .overlay(alignment: .top) {
                                LinearGradient(colors: [Color.white.opacity(0.16), .clear],
                                               startPoint: .top, endPoint: .center)
                            }
                            .overlay(alignment: .leading) {
                                Rectangle().fill(MonitorDesign.bg0.opacity(0.5)).frame(width: 1)
                            }
                    }
                }
            }
        }
        .background(MonitorDesign.track)
        .clipShape(Capsule())
    }
}

// MARK: - Previews

#if DEBUG
private func usagePreviewContext(
    size: MonitorWidgetSize,
    usage: MonitorUsageSnapshot?,
    history: MonitorHistorySnapshot = MonitorHistorySnapshot()
) -> MonitorWidgetContext {
    var snapshot = MonitorSnapshot(timestamp: Date().timeIntervalSince1970)
    snapshot.usage = usage
    return MonitorWidgetContext(
        snapshot: snapshot,
        history: history,
        placement: MonitorWidgetPlacement(kind: .usage, size: size),
        isEditing: false,
        isAgentFleetEnabled: true,
        reduceMotion: false,
        now: Date()
    )
}

private func normalUsage(stale: Bool = false) -> MonitorUsageSnapshot {
    var u = MonitorUsageSnapshot()
    let now = Date().timeIntervalSince1970
    u.fiveHourUsedPercent = 0.58
    u.fiveHourResetsAt = now + 2 * 3600 + 14 * 60
    u.weekUsedPercent = 0.63
    u.weekResetsAt = now + 3 * 86400 + 5 * 3600
    u.costTodayUSD = 12.4
    u.tokensToday = MonitorTokenTotals(
        input: 1_180_000, output: 960_000, cacheRead: 5_210_000, cacheWrite: 1_070_000)
    u.limitsStale = stale
    u.perProvider = [
        "claude": MonitorProviderUsage(costTodayUSD: 8.10, tokensToday: MonitorTokenTotals(input: 3_800_000, output: 1_880_000)),
        "codex": MonitorProviderUsage(costTodayUSD: 4.30, tokensToday: MonitorTokenTotals(input: 1_900_000, output: 840_000))
    ]
    u.dailyActivity = [4.1, 6.8, 3.2, 9.4, 7.1, 5.5, 8.42].map { m in
        MonitorUsageDayBucket(day: "2026-07-0x",
                              tokens: MonitorTokenTotals(input: Int(m * 1_000_000)))
    }
    u.tokenBurnRatePerHour = 1_240_000
    u.costBurnRatePerHour = 2.6
    u.perModel = [
        MonitorUsageModelBreakdown(model: "claude-opus-4-20250514",
                                   tokens: MonitorTokenTotals(input: 3_100_000, output: 1_400_000, cacheRead: 4_200_000), costUSD: 8.1),
        MonitorUsageModelBreakdown(model: "claude-sonnet-5",
                                   tokens: MonitorTokenTotals(input: 1_900_000, output: 820_000, cacheRead: 2_600_000), costUSD: 3.2),
        MonitorUsageModelBreakdown(model: "gpt-5",
                                   tokens: MonitorTokenTotals(input: 1_400_000, output: 610_000), costUSD: nil),
        MonitorUsageModelBreakdown(model: "claude-haiku",
                                   tokens: MonitorTokenTotals(input: 420_000, output: 180_000), costUSD: 0.4)
    ]
    return u
}

private func hotUsage() -> MonitorUsageSnapshot {
    var u = MonitorUsageSnapshot()
    let now = Date().timeIntervalSince1970
    u.fiveHourUsedPercent = 0.91
    u.fiveHourResetsAt = now + 26 * 60
    u.weekUsedPercent = 0.88
    u.weekResetsAt = now + 2 * 86400 + 3 * 3600
    u.costTodayUSD = 41.7
    u.tokensToday = MonitorTokenTotals(
        input: 4_900_000, output: 3_200_000, cacheRead: 15_600_000, cacheWrite: 3_100_000)
    u.limitsStale = false
    u.perProvider = [
        "claude": MonitorProviderUsage(costTodayUSD: 27.30, tokensToday: MonitorTokenTotals(input: 12_000_000, output: 6_100_000)),
        "codex": MonitorProviderUsage(costTodayUSD: 14.40, tokensToday: MonitorTokenTotals(input: 6_000_000, output: 2_700_000))
    ]
    u.dailyActivity = [4.1, 6.8, 3.2, 9.4, 7.1, 14.9, 26.8].map { m in
        MonitorUsageDayBucket(day: "2026-07-0x",
                              tokens: MonitorTokenTotals(input: Int(m * 1_000_000)))
    }
    u.tokenBurnRatePerHour = 5_600_000
    u.costBurnRatePerHour = 11.2
    u.perModel = [
        MonitorUsageModelBreakdown(model: "claude-opus-4-20250514",
                                   tokens: MonitorTokenTotals(input: 9_800_000, output: 4_100_000, cacheRead: 11_200_000), costUSD: 27.3),
        MonitorUsageModelBreakdown(model: "gpt-5",
                                   tokens: MonitorTokenTotals(input: 5_100_000, output: 2_300_000), costUSD: nil),
        MonitorUsageModelBreakdown(model: "claude-sonnet-5",
                                   tokens: MonitorTokenTotals(input: 3_200_000, output: 1_400_000), costUSD: 6.1)
    ]
    return u
}

/// A rising 5h-used% series that yields a live ~38m ETA to the cap.
private func risingHistory(current: Double) -> MonitorHistorySnapshot {
    var h = MonitorHistorySnapshot()
    let base = Date().timeIntervalSince1970 - 600
    // +~0.0067/min → from `current`, remaining reaches 1.0 in a live window.
    let step = 0.011
    for i in 0..<6 {
        h.usageQuotaTimes.append(base + Double(i) * 120)
        h.usageFiveHourUsed.append(current - 0.05 + Double(i) * step)
    }
    return h
}

/// No-quota degraded snapshot: statusline not installed, only token tail exists.
private func noQuotaUsage() -> MonitorUsageSnapshot {
    var u = MonitorUsageSnapshot()
    u.costTodayUSD = 3.2
    u.tokensToday = MonitorTokenTotals(input: 620_000, output: 210_000, cacheRead: 1_100_000)
    u.dailyActivity = [1.1, 2.2, 0, 3.4, 2.1, 1.5, 0.83].map { m in
        MonitorUsageDayBucket(day: "2026-07-0x", tokens: MonitorTokenTotals(input: Int(m * 1_000_000)))
    }
    u.perModel = [
        MonitorUsageModelBreakdown(model: "claude-sonnet-5",
                                   tokens: MonitorTokenTotals(input: 620_000, output: 210_000, cacheRead: 1_100_000), costUSD: 1.8),
        MonitorUsageModelBreakdown(model: "claude-haiku",
                                   tokens: MonitorTokenTotals(input: 180_000, output: 60_000), costUSD: 0.2)
    ]
    return u
}

#Preview("Usage S — normal") {
    MonitorUsageWidgetView(context: usagePreviewContext(size: .small, usage: normalUsage()))
        .frame(width: 170, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage S — near-limit") {
    MonitorUsageWidgetView(context: usagePreviewContext(size: .small, usage: hotUsage()))
        .frame(width: 170, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage S — stale") {
    MonitorUsageWidgetView(context: usagePreviewContext(size: .small, usage: normalUsage(stale: true)))
        .frame(width: 170, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage S — no quota") {
    MonitorUsageWidgetView(context: usagePreviewContext(size: .small, usage: noQuotaUsage()))
        .frame(width: 170, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage S — setup needed") {
    MonitorUsageWidgetView(context: usagePreviewContext(size: .small, usage: nil))
        .frame(width: 170, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage M — normal + ETA") {
    MonitorUsageWidgetView(context: usagePreviewContext(
        size: .medium, usage: normalUsage(), history: risingHistory(current: 0.58)))
        .frame(width: 364, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage M — near-limit") {
    MonitorUsageWidgetView(context: usagePreviewContext(
        size: .medium, usage: hotUsage(), history: risingHistory(current: 0.91)))
        .frame(width: 364, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage M — stale") {
    MonitorUsageWidgetView(context: usagePreviewContext(size: .medium, usage: normalUsage(stale: true)))
        .frame(width: 364, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage M — no quota") {
    MonitorUsageWidgetView(context: usagePreviewContext(size: .medium, usage: noQuotaUsage()))
        .frame(width: 364, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage M — setup needed") {
    MonitorUsageWidgetView(context: usagePreviewContext(size: .medium, usage: nil))
        .frame(width: 364, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage L — normal + ETA") {
    MonitorUsageWidgetView(context: usagePreviewContext(
        size: .large, usage: normalUsage(), history: risingHistory(current: 0.58)))
        .frame(width: 364, height: 376)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage L — near-limit") {
    MonitorUsageWidgetView(context: usagePreviewContext(
        size: .large, usage: hotUsage(), history: risingHistory(current: 0.91)))
        .frame(width: 364, height: 376)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage L — no quota") {
    MonitorUsageWidgetView(context: usagePreviewContext(size: .large, usage: noQuotaUsage()))
        .frame(width: 364, height: 376)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Usage L — stale") {
    MonitorUsageWidgetView(context: usagePreviewContext(size: .large, usage: normalUsage(stale: true)))
        .frame(width: 364, height: 376)
        .padding(32)
        .background(MonitorDesign.boardWash)
}
#endif
