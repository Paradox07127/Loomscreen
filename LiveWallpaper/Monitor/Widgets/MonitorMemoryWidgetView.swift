import SwiftUI
import LiveWallpaperCore

/// Native replica of the Memory widget from the approved design
/// (`.claude/plan/monitor-design/index.html`, `buildMemorySection`), revised by
/// the on-device review.
///
/// Pressure stays a first-class signal (Apple's stance: free RAM ≠ fast,
/// memory-verdict ④) but is carried ONLY by the discrete chip/dot — never by
/// chart colour. History is coloured by CATEGORY: the trend stacks
/// App/Wired/Compressed as bands in the same tones as the Activity-Monitor
/// breakdown bar, with the used% curve as the top edge. `memUsedBytes` is
/// already the Activity-Monitor formula (App + Wired + Compressed; Cached
/// Files excluded), so the top edge ≈ the bands' sum.
///
/// Sizes are Apple's fixed widget frames (S 170×170 / M 364×170 / L 364×376);
/// the type scale is cell-derived (frame ÷ 2·rowSpan), the CPU widget's idiom.
///
/// - S (170×170): a purely graphical tank (level = used%, tint = pressure)
///   beside used% as the hero read, the pressure word as a dot-tagged secondary
///   line, and a swap chip when relevant.
/// - M (364×170): used/total hero + pressure chip, the AM breakdown bar with a
///   3-column valued legend, and a ~60s stacked category micro-trend.
/// - L (364×376, `mem_l`): NO tank. Hero + pressure chip + swap caption on one
///   row, the stacked trend widened to a ~120s window (the breakdown legend
///   below explains its colours), the AM breakdown (bar + legend), and a
///   "Top by memory" list (`topProcesses` re-ranked by `memBytes`, top-5, each
///   row name + cpu% + GiB in fixed right-aligned columns) — the extra height
///   buys a process ranking, never bigger type (SPEC §3.0 3-size-cap).
struct MonitorMemoryWidgetView: View {
    let context: MonitorWidgetContext

    private var system: MonitorSystemSnapshot? { context.snapshot.system }
    private var pressure: MonitorPressure {
        MonitorMemoryWidgetView.pressure(system?.memPressure)
    }

    var body: some View {
        GeometryReader { geo in
            // Fixed Apple frames: S/M span one board row, L two — dividing by
            // 2·rowSpan recovers the mock's cell-derived type scale (CPU idiom).
            let rowSpan: CGFloat = context.placement.size == .large ? 2 : 1
            let cellHeight = geo.size.height / (2 * rowSpan)
            MonitorWidgetContainer(
                label: "MEM",
                cellHeight: cellHeight,
                status: { statusDot }
            ) {
                switch context.placement.size {
                case .small: small(cellHeight: cellHeight)
                case .medium: medium(cellHeight: cellHeight)
                case .large: large(cellHeight: cellHeight)
                }
            }
        }
    }

    // MARK: - Header status dot

    /// The chd dot in the mock: warm on warning, coral on critical, hidden on normal.
    @ViewBuilder
    private var statusDot: some View {
        switch pressure {
        case .normal: EmptyView()
        case .warn: BreathingDot(color: MonitorDesign.signalAmber, size: 6)
        case .critical: BreathingDot(color: MonitorDesign.signalCoral, size: 6)
        }
    }

    // MARK: - S (2×2): tank + used% hero

    @ViewBuilder
    private func small(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        HStack(alignment: .center, spacing: 10) {
            // Purely graphical — no in-tank readout (on-device review).
            TankGauge(level: memUsedFraction, pressure: pressure,
                      cornerRadius: max(6, cellHeight * 0.06))
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 3) {
                Spacer(minLength: 0)
                // used% is the S hero read; the "%" is a separately-styled unit
                // (CPU hero idiom) so the numeral carries the weight.
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(verbatim: "\(usedPercentInt)")
                        .font(MonitorDesign.heroFont(size: scale.hero * 0.86))
                        .foregroundStyle(MonitorDesign.inkPrimary)
                    Text(verbatim: "%")
                        .font(MonitorDesign.heroFont(size: scale.hero * 0.86 * 0.4))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                Text(verbatim: "USED")
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(MonitorDesign.labelTracking(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
                // Pressure demotes to a dot-tagged secondary line; the word
                // (Normal/Warning/Critical) stays localized via existing keys.
                HStack(spacing: 4) {
                    Circle()
                        .fill(pressureDotColor)
                        .frame(width: scale.label * 0.6, height: scale.label * 0.6)
                        .shadow(color: pressureDotColor.opacity(0.7), radius: 2)
                    Text(MonitorMemoryWidgetView.pressureDisplayKey(pressure))
                        .font(MonitorDesign.subFont(size: scale.sub * 0.78))
                        .foregroundStyle(pressureHeroColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.top, 1)
                if showsSwap {
                    // "Swap" reuses the app's existing catalog key; the "N.NG"
                    // figure is data (verbatim).
                    (Text("Swap") + Text(verbatim: " \(swapGiBString)G"))
                        .font(MonitorDesign.labelFont(size: scale.label))
                        .tracking(scale.label * 0.06)
                        .foregroundStyle(MonitorDesign.signalSteel)
                        .monitorChip(scale)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - M (4×2): hero + pressure chip + AM breakdown + trend

    @ViewBuilder
    private func medium(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        VStack(alignment: .leading, spacing: 6) {
            // hero (used/total) + pressure chip — mock uses align-items:center
            HStack(alignment: .center, spacing: 6) {
                heroLine(scale: scale, factor: 0.86)
                Spacer(minLength: 4)
                PressureChip(pressure: pressure, scale: scale)
            }

            // 3-col legend: the 125pt content box leaves ~40pt for the trend, so
            // the legend flattens to two rows instead of three.
            breakdownBlock(scale: scale, legendColumns: 3)

            // Category-stacked micro-trend (window from the `historyWindow`
            // option, default 60s) — the legend above already explains the
            // App/Wired/Compressed tones, so no chart-corner chip.
            MemoryStackChart(
                app: recentSeries(\.memAppFraction),
                wired: recentSeries(\.memWiredFraction),
                compressed: recentSeries(\.memCompressedFraction),
                used: recentSeries(\.memUsedFraction)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - L (4×4): hero + pressure chip + swap caption, 120s merged curve
    // with a normal/warn/crit legend, AM breakdown, and a "Top by memory" list.

    @ViewBuilder
    private func large(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        VStack(alignment: .leading, spacing: 8) {
            // header: hero + pressure chip + swap caption on one row (mock's
            // flex-wrap header — no tank at L, the curve carries the read).
            HStack(alignment: .center, spacing: 8) {
                heroLine(scale: scale, factor: 0.9)
                Spacer(minLength: 6)
                if showsSwap {
                    // The 332pt row can't always take hero + chip + swap side by
                    // side (long localized pressure words); stacked-trailing costs
                    // no height — the hero line already sets the row.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            PressureChip(pressure: pressure, scale: scale)
                            swapCaption(scale: scale)
                        }
                        VStack(alignment: .trailing, spacing: 3) {
                            PressureChip(pressure: pressure, scale: scale)
                            swapCaption(scale: scale)
                        }
                    }
                } else {
                    PressureChip(pressure: pressure, scale: scale)
                }
            }

            // The stacked category trend widened to `historyWindow` (default
            // 120s at L). Its colours are keyed by the breakdown legend below —
            // no separate chart legend or "colour = pressure" chip.
            MemoryStackChart(
                app: recentSeries(\.memAppFraction),
                wired: recentSeries(\.memWiredFraction),
                compressed: recentSeries(\.memCompressedFraction),
                used: recentSeries(\.memUsedFraction)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 56)

            breakdownBlock(scale: scale, headerLabel: "BREAKDOWN")

            if showsTopProcesses {
                topByMemoryBlock(scale: scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The dashed-swap caption used beside the L header's pressure chip (mock's
    /// `┄ swap X.XG`, same dashed glyph the M trend legend uses for swap).
    private func swapCaption(scale: MonitorDesign.TypeScale) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: "┄")
                .foregroundStyle(MonitorDesign.signalSteel)
            Text("Swap")
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: "\(swapGiBString)G")
                .foregroundStyle(MonitorDesign.inkMuted)
        }
        .font(MonitorDesign.captionFont(size: scale.label * 0.96))
        .monospacedDigit()
        .lineLimit(1)
        .monitorChip(scale)
    }

    /// The Activity-Monitor breakdown bar + valued legend, shared by M and L.
    /// The legend is omitted in "compact" mode (`breakdown` option) — the bar
    /// alone still carries the true proportions, just without the per-segment
    /// GiB readout.
    @ViewBuilder
    private func breakdownBlock(
        scale: MonitorDesign.TypeScale, headerLabel: String? = nil, legendColumns: Int = 2
    ) -> some View {
        if let breakdown = system?.memBreakdown, let total = memTotalBytes, total > 0 {
            let segments = MonitorMemoryWidgetView.segments(
                breakdown: breakdown, swap: system?.swapUsedBytes ?? 0, total: total
            )
            VStack(alignment: .leading, spacing: 4) {
                if let headerLabel {
                    Text(verbatim: headerLabel)
                        .font(MonitorDesign.labelFont(size: scale.label))
                        .tracking(MonitorDesign.labelTracking(size: scale.label))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
                MemoryBreakdownBar(segments: segments,
                                   freeFraction: MonitorMemoryWidgetView.freeFraction(
                                       breakdown: breakdown, total: total))
                    .frame(height: scale.caption * 1.05)
                if !breakdownCompact {
                    MemoryBreakdownLegend(segments: segments, labelSize: scale.label,
                                          columns: legendColumns)
                }
            }
        }
    }

    /// "Top by memory" — the honest RSS ranking (mock `memProcs`): the shared
    /// `topProcesses` feed re-sorted by `memBytes` descending, top-5, each row
    /// a name + an inline App-gold bar (share of the busiest shown row) + GiB.
    @ViewBuilder
    private func topByMemoryBlock(scale: MonitorDesign.TypeScale) -> some View {
        VStack(alignment: .leading, spacing: scale.caption * 0.32) {
            // Section micro-label — verbatim like this file's other axis labels
            // (PRESSURE / USED / BREAKDOWN) and the AI-Engine widget's PROGRAM /
            // ANE MEM, never a new localizable string.
            Text(verbatim: "TOP BY MEMORY")
                .font(MonitorDesign.labelFont(size: scale.label))
                .tracking(MonitorDesign.labelTracking(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
            let procs = topMemoryProcesses
            if procs.isEmpty {
                Text("no process readings")
                    .font(MonitorDesign.captionFont(size: scale.caption))
                    .foregroundStyle(MonitorDesign.inkFaint)
            } else {
                let top = procs.first?.memBytes ?? 0
                ForEach(Array(procs.enumerated()), id: \.offset) { _, proc in
                    MemoryTopProcessRow(proc: proc, topBytes: top, scale: scale)
                }
            }
        }
    }

    @ViewBuilder
    private func heroLine(scale: MonitorDesign.TypeScale, factor: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: usedGiBString)
                .font(MonitorDesign.heroFont(size: scale.hero * factor))
                .foregroundStyle(MonitorDesign.inkPrimary)
            Text(verbatim: "/ \(totalGiBString)G")
                .font(MonitorDesign.subFont(size: scale.hero * factor * 0.4))
                .foregroundStyle(MonitorDesign.inkMuted)
        }
        .monospacedDigit()
    }

    // MARK: - Derived values

    private var memTotalBytes: Double? {
        guard let total = system?.memTotalBytes, total > 0 else { return nil }
        return Double(total)
    }

    private var memUsedFraction: Double {
        guard let system, system.memTotalBytes > 0 else { return 0 }
        return min(1, max(0, Double(system.memUsedBytes) / Double(system.memTotalBytes)))
    }

    private var usedPercentInt: Int { Int((memUsedFraction * 100).rounded()) }

    private var usedGiBString: String {
        String(format: "%.1f", MonitorFormat.gib(Double(system?.memUsedBytes ?? 0)))
    }

    private var totalGiBString: String {
        String(format: "%.0f", MonitorFormat.gib(Double(system?.memTotalBytes ?? 0)))
    }

    private var swapGiBString: String {
        String(format: "%.1f", MonitorFormat.gib(Double(system?.swapUsedBytes ?? 0)))
    }

    /// Swap emphasised only when actually present or under pressure (SPEC §3.1).
    private var showsSwap: Bool {
        MonitorMemoryWidgetView.showsSwap(
            swapBytes: system?.swapUsedBytes, pressure: system?.memPressure)
    }

    private var pressureHeroColor: Color {
        switch pressure {
        case .normal: return MonitorDesign.oklch(0.84, 0.09, 158)
        case .warn: return MonitorDesign.oklch(0.86, 0.11, 66)
        case .critical: return MonitorDesign.signalCoral
        }
    }

    /// The S secondary line's pressure dot — same signal tones as `PressureChip`.
    private var pressureDotColor: Color {
        switch pressure {
        case .normal: return MonitorDesign.signalSage
        case .warn: return MonitorDesign.signalAmber
        case .critical: return MonitorDesign.signalCoral
        }
    }

    /// Most-recent samples of a history series for the M/L trend, sized by
    /// `trendWindowSamples`. All four memory series are ingested/trimmed in
    /// lockstep, so equal suffixes stay sample-aligned.
    private func recentSeries(_ series: KeyPath<MonitorHistorySnapshot, [Double]>) -> [Double] {
        Array(context.history[keyPath: series].suffix(trendWindowSamples))
    }

    /// The `historyWindow` widget option (seconds), resolved against a
    /// size-specific default (M 60, L 120 — mock `mem_m`/`mem_l`). The board
    /// samples at ~1Hz, so seconds ≈ samples — the same simplifying assumption
    /// every other Monitor widget's trend label already makes. (Field contract:
    /// mock index.html:3641 `Memory{historyWindow}`.)
    private var trendWindowSamples: Int {
        let fallback = context.placement.size == .large ? 120 : 60
        return MonitorMemoryWidgetView.historyWindowSamples(
            optionSeconds: context.placement.options["historyWindow"]?.numberValue,
            fallbackSeconds: fallback)
    }

    /// The `showTopProcesses` widget option (default true) — gates the L-only
    /// "Top by memory" list. (Field contract: mock index.html:3641.)
    private var showsTopProcesses: Bool {
        MonitorMemoryWidgetView.showsTopProcesses(
            context.placement.options["showTopProcesses"]?.boolValue)
    }

    /// The `breakdown` widget option ("full" default / "compact") — compact
    /// keeps the AM bar (true proportions) but omits the per-segment GiB legend.
    /// (Field contract: mock index.html:3641 `Memory{breakdown}`.)
    private var breakdownCompact: Bool {
        MonitorMemoryWidgetView.breakdownIsCompact(
            context.placement.options["breakdown"]?.stringValue)
    }

    /// Top-5 processes by RSS (`topProcesses` re-ranked by `memBytes`) for the
    /// L "Top by memory" list.
    private var topMemoryProcesses: [MonitorProcessSample] {
        MonitorMemoryWidgetView.topByMemory(system?.topProcesses, limit: 5)
    }

    // MARK: - Pure helpers (shared with tests)

    /// String pressure → tank/chip pressure enum.
    nonisolated static func pressure(_ raw: String?) -> MonitorPressure {
        switch raw {
        case "critical", "crit": return .critical
        case "warn", "warning": return .warn
        default: return .normal
        }
    }

    /// Discrete pressure level (0 normal / 1 warn / 2 crit). The UI no longer
    /// colours the trend by pressure; kept because the contract is pinned by tests.
    nonisolated static func pressureLevel(_ raw: String?) -> Int {
        switch pressure(raw) {
        case .normal: return 0
        case .warn: return 1
        case .critical: return 2
        }
    }

    /// Localized display key for a pressure state. Reuses the app's existing
    /// capitalized catalog entries (Normal / Warning / Critical) so no case-variant
    /// duplicate key is introduced.
    nonisolated static func pressureDisplayKey(_ p: MonitorPressure) -> LocalizedStringKey {
        switch p {
        case .normal: return "Normal"
        case .warn: return "Warning"
        case .critical: return "Critical"
        }
    }

    /// Swap is emphasised only when it's non-zero or pressure has risen above normal.
    nonisolated static func showsSwap(swapBytes: UInt64?, pressure raw: String?) -> Bool {
        if let swapBytes, swapBytes > 0 { return true }
        return pressure(raw) != .normal
    }

    /// Resolve the `historyWindow` option (seconds) against a size-specific
    /// fallback. A non-finite/non-positive override is ignored (never a
    /// zero-length or negative window); the sample count floor is 2.
    nonisolated static func historyWindowSamples(optionSeconds: Double?, fallbackSeconds: Int) -> Int {
        guard let optionSeconds, optionSeconds.isFinite, optionSeconds > 0 else {
            return fallbackSeconds
        }
        return max(2, Int(optionSeconds.rounded()))
    }

    /// `showTopProcesses` option: absent ⇒ shown (mock popover default `on`).
    nonisolated static func showsTopProcesses(_ raw: Bool?) -> Bool { raw ?? true }

    /// `breakdown` option: only the literal `"compact"` collapses the legend;
    /// anything else (including absent) is the full/default split.
    nonisolated static func breakdownIsCompact(_ raw: String?) -> Bool { raw == "compact" }

    /// Top processes by RSS (`memBytes`), descending, ties broken by original
    /// order, capped to `limit`. `nil`/empty in → empty out (SPEC §3.4: an
    /// absent sampler means "not sampling", never a fabricated empty ranking).
    nonisolated static func topByMemory(
        _ processes: [MonitorProcessSample]?, limit: Int
    ) -> [MonitorProcessSample] {
        guard let processes, !processes.isEmpty else { return [] }
        let sorted = processes.enumerated().sorted { lhs, rhs in
            if lhs.element.memBytes != rhs.element.memBytes {
                return lhs.element.memBytes > rhs.element.memBytes
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Bar length = this row's RSS ÷ the busiest shown row's RSS, 0…1. A zero
    /// top yields an empty bar rather than a divide-by-zero.
    nonisolated static func processBarFraction(_ bytes: UInt64, top: UInt64) -> Double {
        guard top > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(top)))
    }

    /// cpu% column for the Top-by-memory rows: whole-number "N%" when the
    /// sample carries a reading, an en-dash when it doesn't — the column keeps
    /// its reserved width either way so the GiB column never shifts.
    nonisolated static func cpuColumnText(_ cpuPercent: Double) -> String {
        guard cpuPercent.isFinite, cpuPercent > 0 else { return "–" }
        return "\(Int(cpuPercent.rounded()))%"
    }

    /// One Activity-Monitor breakdown segment (fraction is 0…1 of total RAM).
    struct Segment: Identifiable, Equatable {
        enum Kind: String {
            case app, wired, compressed, cached, swap

            /// Localized display key for the legend. "App"/"Swap" reuse the app's
            /// existing catalog entries; the rest have their own keys.
            var displayKey: LocalizedStringKey {
                switch self {
                case .app: return "App"
                case .wired: return "Wired"
                case .compressed: return "Compressed"
                case .cached: return "Cached Files"
                case .swap: return "Swap"
                }
            }
        }
        var kind: Kind
        var label: String
        var bytes: Double
        var fraction: Double
        var id: String { kind.rawValue }
    }

    /// App / Wired / Compressed / Cached Files / Swap, each a fraction of total RAM.
    /// Order and labels match the mock's `AM_SEGS` exactly. Swap is off-RAM but the
    /// mock still scales its width by total RAM, so it's treated the same here.
    nonisolated static func segments(
        breakdown: MonitorMemoryBreakdown, swap: UInt64, total: Double
    ) -> [Segment] {
        let t = max(total, 1)
        func frac(_ v: UInt64) -> Double { min(1, max(0, Double(v) / t)) }
        return [
            Segment(kind: .app, label: "App", bytes: Double(breakdown.appBytes),
                    fraction: frac(breakdown.appBytes)),
            Segment(kind: .wired, label: "Wired", bytes: Double(breakdown.wiredBytes),
                    fraction: frac(breakdown.wiredBytes)),
            Segment(kind: .compressed, label: "Compressed", bytes: Double(breakdown.compressedBytes),
                    fraction: frac(breakdown.compressedBytes)),
            Segment(kind: .cached, label: "Cached Files", bytes: Double(breakdown.cachedFilesBytes),
                    fraction: frac(breakdown.cachedFilesBytes)),
            Segment(kind: .swap, label: "Swap", bytes: Double(swap),
                    fraction: frac(swap)),
        ]
    }

    /// Free RAM = whatever's left after the four RAM segments (swap is off-RAM and
    /// is NOT subtracted — mirrors the mock's `amBar` free calc).
    nonisolated static func freeFraction(breakdown: MonitorMemoryBreakdown, total: Double) -> Double {
        let ramUsed = Double(breakdown.appBytes) + Double(breakdown.wiredBytes)
            + Double(breakdown.compressedBytes) + Double(breakdown.cachedFilesBytes)
        return min(1, max(0, 1 - ramUsed / max(total, 1)))
    }

    /// Split a series into runs of constant pressure, each sharing its boundary
    /// sample with the next. No longer drawn (the trend now stacks categories);
    /// kept because the contract is pinned by tests.
    nonisolated static func pressureRuns(count: Int, level: (Int) -> Int) -> [(range: ClosedRange<Int>, level: Int)] {
        guard count > 0 else { return [] }
        var runs: [(ClosedRange<Int>, Int)] = []
        var start = 0
        var runLevel = level(0)
        for i in 1..<count {
            let lv = level(i)
            if lv != runLevel {
                // The boundary sample belongs to BOTH runs (shared vertex).
                runs.append((start...i, runLevel))
                start = i
                runLevel = lv
            }
        }
        runs.append((start...(count - 1), runLevel))
        return runs
    }
}

// MARK: - Pressure chip

/// Discrete pressure state chip (never a %). Ported from `.pchip`.
private struct PressureChip: View {
    var pressure: MonitorPressure
    var scale: MonitorDesign.TypeScale

    private var labelSize: CGFloat { scale.label }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: labelSize * 0.6, height: labelSize * 0.6)
                .shadow(color: dotColor.opacity(0.7), radius: 3)
            Text(verbatim: "PRESSURE")
                .font(MonitorDesign.labelFont(size: labelSize * 0.9))
                .tracking(labelSize * 0.11)
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(MonitorMemoryWidgetView.pressureDisplayKey(pressure))
                .font(MonitorDesign.labelFont(size: labelSize))
                .foregroundStyle(valueColor)
        }
        .monitorChip(scale)
        .fixedSize()
    }

    private var dotColor: Color {
        switch pressure {
        case .normal: return MonitorDesign.signalSage
        case .warn: return MonitorDesign.signalAmber
        case .critical: return MonitorDesign.signalCoral
        }
    }

    private var valueColor: Color {
        switch pressure {
        case .normal: return MonitorDesign.oklch(0.86, 0.07, 158)
        case .warn: return MonitorDesign.oklch(0.90, 0.05, 46)
        case .critical: return MonitorDesign.oklch(0.92, 0.06, 38)
        }
    }
}

// MARK: - Activity-Monitor breakdown bar + legend

/// The five AM tones — App warm-amber, Wired ochre, Compressed rose-taupe,
/// Cached steel-sage (reclaimable), Swap cool steel — matching the mock's
/// `.ambar .aseg.*` gradients. Cached is deliberately dimmer (it's "free-ish").
private enum AMSegmentStyle {
    static func gradient(_ kind: MonitorMemoryWidgetView.Segment.Kind) -> LinearGradient {
        LinearGradient(colors: colors(kind), startPoint: .leading, endPoint: .trailing)
    }

    static func swatch(_ kind: MonitorMemoryWidgetView.Segment.Kind) -> LinearGradient {
        // Legend swatch — the mock uses a single representative tone (its `--c`).
        LinearGradient(colors: [legendColor(kind)], startPoint: .top, endPoint: .bottom)
    }

    static func colors(_ kind: MonitorMemoryWidgetView.Segment.Kind) -> [Color] {
        switch kind {
        case .app: return [MonitorDesign.oklch(0.62, 0.06, 82), MonitorDesign.oklch(0.74, 0.12, 80)]
        case .wired: return [MonitorDesign.oklch(0.60, 0.09, 55), MonitorDesign.oklch(0.70, 0.13, 50)]
        case .compressed: return [MonitorDesign.oklch(0.56, 0.08, 30), MonitorDesign.oklch(0.66, 0.12, 32)]
        case .cached: return [MonitorDesign.oklch(0.46, 0.03, 150), MonitorDesign.oklch(0.42, 0.028, 150)]
        case .swap: return [MonitorDesign.oklch(0.46, 0.035, 240), MonitorDesign.oklch(0.60, 0.06, 236)]
        }
    }

    /// The single representative legend tone from the mock's `AM_SEGS[].c`.
    static func legendColor(_ kind: MonitorMemoryWidgetView.Segment.Kind) -> Color {
        switch kind {
        case .app: return MonitorDesign.oklch(0.70, 0.11, 80)
        case .wired: return MonitorDesign.oklch(0.66, 0.12, 52)
        case .compressed: return MonitorDesign.oklch(0.62, 0.11, 31)
        case .cached: return MonitorDesign.oklch(0.50, 0.03, 150)
        case .swap: return MonitorDesign.oklch(0.56, 0.055, 238)
        }
    }
}

private struct MemoryBreakdownBar: View {
    var segments: [MonitorMemoryWidgetView.Segment]
    var freeFraction: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                ForEach(segments) { seg in
                    if seg.fraction > 0 {
                        AMSegmentStyle.gradient(seg.kind)
                            .frame(width: max(1, w * CGFloat(seg.fraction)))
                            .overlay(alignment: .top) {
                                LinearGradient(
                                    colors: [Color.white.opacity(0.16), .clear],
                                    startPoint: .top, endPoint: .center
                                )
                            }
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(MonitorDesign.bg0.opacity(0.55)).frame(width: 1)
                            }
                    }
                }
                if freeFraction > 0.005 {
                    Rectangle().fill(Color.clear)
                        .frame(width: max(0, w * CGFloat(freeFraction)))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(MonitorDesign.hairline.opacity(0.4)).frame(width: 1)
                        }
                }
            }
        }
        .background(MonitorDesign.track)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct MemoryBreakdownLegend: View {
    var segments: [MonitorMemoryWidgetView.Segment]
    var labelSize: CGFloat
    /// 2 at L (mock's grid), 3 at M — the 125pt M content box only affords two
    /// legend rows, so the 332pt width absorbs the extra column instead.
    var columns: Int = 2

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: max(1, columns))
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 3) {
            ForEach(segments) { seg in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(AMSegmentStyle.swatch(seg.kind))
                        .frame(width: labelSize * 0.62, height: labelSize * 0.62)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                        )
                    // AM segment label (App/Wired/Compressed/Cached Files/Swap) —
                    // words a human reads, localized via the kind's display key.
                    Text(seg.kind.displayKey)
                        .font(MonitorDesign.captionFont(size: labelSize))
                        .foregroundStyle(MonitorDesign.inkFaint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Text(verbatim: gib(seg.bytes))
                        .font(MonitorDesign.subFont(size: labelSize))
                        .monospacedDigit()
                        .foregroundStyle(MonitorDesign.inkPrimary)
                }
            }
        }
    }

    private func gib(_ bytes: Double) -> String {
        String(format: "%.1fG", MonitorFormat.gib(bytes))
    }
}

// MARK: - "Top by memory" row (L only)

/// One RSS-ranked row (mock `.proc .pr`, memory column repurposed): a leading
/// glyph + truncating name, an inline bar sharing the App segment's warm-gold
/// gradient, then cpu% and GiB in FIXED-width right-aligned columns — the name
/// truncates, the numbers never do (on-device review: the rightmost value must
/// not clip, and the columns must not shift between rows).
private struct MemoryTopProcessRow: View {
    var proc: MonitorProcessSample
    var topBytes: UInt64
    var scale: MonitorDesign.TypeScale

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: scale.caption * 0.5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(MonitorDesign.inkFaint.opacity(0.7))
                    .frame(width: scale.caption * 0.5, height: scale.caption * 0.5)
                Text(verbatim: proc.name)
                    .font(MonitorDesign.captionFont(size: scale.caption))
                    .foregroundStyle(MonitorDesign.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(MonitorDesign.track2)
                    Capsule(style: .continuous)
                        .fill(AMSegmentStyle.gradient(.app))
                        .frame(width: max(0, g.size.width * CGFloat(
                            MonitorMemoryWidgetView.processBarFraction(proc.memBytes, top: topBytes))))
                }
            }
            .frame(width: scale.caption * 3.0, height: scale.caption * 0.42)

            // cpu% column — sized for a multi-core "NNN%"; dim when not carried.
            Text(verbatim: MonitorMemoryWidgetView.cpuColumnText(proc.cpuPercent))
                .font(MonitorDesign.subFont(size: scale.caption * 0.94))
                .monospacedDigit()
                .foregroundStyle(proc.cpuPercent > 0 ? MonitorDesign.inkMuted : MonitorDesign.inkFaint)
                .frame(width: scale.caption * 2.9, alignment: .trailing)

            Text(verbatim: gib(proc.memBytes))
                .font(MonitorDesign.subFont(size: scale.caption * 0.94))
                .monospacedDigit()
                .foregroundStyle(AMSegmentStyle.legendColor(.app))
                .frame(width: scale.caption * 3.3, alignment: .trailing)
        }
        .lineLimit(1)
    }

    private func gib(_ bytes: UInt64) -> String {
        String(format: "%.1fG", MonitorFormat.gib(Double(bytes)))
    }
}

// MARK: - Category-stacked used% history (M + L trend)

/// Stacked App/Wired/Compressed bands (fractions of total RAM) in the SAME
/// tones as the AM breakdown bar, so the breakdown legend explains this chart
/// too — a local port of the CPU widget's `CPUStackChart` idiom. The used%
/// curve is stroked separately as the crisp top edge: used ≈ the bands' sum
/// (AM formula), and the edge stays honest on ticks that carried no breakdown
/// (bands collapse to 0, the total curve remains). Fixed 0…1 axis; a neutral
/// now-dot marks the head — pressure never colours this chart.
private struct MemoryStackChart: View {
    var app: [Double]
    var wired: [Double]
    var compressed: [Double]
    var used: [Double]

    private static let inset: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = min(min(app.count, wired.count), min(compressed.count, used.count))
            if n >= 2 {
                let a = Array(app.suffix(n)), wi = Array(wired.suffix(n))
                let c = Array(compressed.suffix(n)), u = Array(used.suffix(n))
                ZStack {
                    baseline(w: w, h: h)
                    Canvas { ctx, size in
                        draw(ctx, size: size, a: a, wi: wi, c: c, u: u, n: n)
                    }
                    Circle()
                        .fill(MonitorDesign.inkMuted)
                        .frame(width: 6, height: 6)
                        .position(x: w, y: y(u[n - 1], h: h))
                        .shadow(color: MonitorDesign.inkMuted.opacity(0.6), radius: 3)
                }
            } else {
                baseline(w: w, h: h)
            }
        }
    }

    private func y(_ f: Double, h: CGFloat) -> CGFloat {
        h - CGFloat(min(1, max(0, f))) * (h - Self.inset * 2) - Self.inset
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize,
                      a: [Double], wi: [Double], c: [Double], u: [Double], n: Int) {
        let w = size.width, h = size.height
        func X(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(n - 1) * w }
        func Y(_ f: Double) -> CGFloat { y(f, h: h) }

        var appTop = [CGPoint](), wiredTop = [CGPoint](), compTop = [CGPoint](), usedTop = [CGPoint]()
        for i in 0..<n {
            appTop.append(CGPoint(x: X(i), y: Y(a[i])))
            wiredTop.append(CGPoint(x: X(i), y: Y(a[i] + wi[i])))
            compTop.append(CGPoint(x: X(i), y: Y(a[i] + wi[i] + c[i])))
            usedTop.append(CGPoint(x: X(i), y: Y(u[i])))
        }

        func area(_ tops: [CGPoint]) -> Path {
            var p = Path()
            // Explicit lineTos: `addLines` would `move` to the first sample and
            // fill a chord instead of the true area down to the baseline.
            p.move(to: CGPoint(x: 0, y: Y(0)))
            for point in tops { p.addLine(to: point) }
            p.addLine(to: CGPoint(x: w, y: Y(0)))
            p.closeSubpath()
            return p
        }
        // Paint taller cumulatives first so each lower band covers its slice.
        let bands: [([CGPoint], MonitorMemoryWidgetView.Segment.Kind, Double)] = [
            (compTop, .compressed, 0.38),
            (wiredTop, .wired, 0.40),
            (appTop, .app, 0.45),
        ]
        for (tops, kind, top) in bands {
            ctx.fill(area(tops), with: .linearGradient(
                Gradient(colors: [AMSegmentStyle.legendColor(kind).opacity(top),
                                  AMSegmentStyle.legendColor(kind).opacity(0.03)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            var line = Path(); line.addLines(tops)
            ctx.stroke(line, with: .color(AMSegmentStyle.legendColor(kind).opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        }
        var totalLine = Path(); totalLine.addLines(usedTop)
        ctx.stroke(totalLine, with: .color(MonitorDesign.inkMuted.opacity(0.9)),
                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private func baseline(w: CGFloat, h: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: h - 1))
            p.addLine(to: CGPoint(x: w, y: h - 1))
        }
        .stroke(MonitorDesign.hairline.opacity(0.45), lineWidth: 1)
    }
}

// MARK: - Previews

#if DEBUG
private func memoryPreviewContext(
    size: MonitorWidgetSize,
    pressure: String,
    swapGiB: Double = 1.1,
    includeProcesses: Bool = true,
    options: [String: MonitorWidgetOptionValue] = [:]
) -> MonitorWidgetContext {
    let g = 1_073_741_824.0
    var system = MonitorSystemSnapshot()
    system.memTotalBytes = UInt64(32 * g)
    system.memBreakdown = MonitorMemoryBreakdown(
        appBytes: UInt64(8.9 * g),
        wiredBytes: UInt64(4.2 * g),
        compressedBytes: UInt64(2.0 * g),
        cachedFilesBytes: UInt64(6.4 * g)
    )
    // used = App + Wired + Compressed (Activity-Monitor formula).
    system.memUsedBytes = UInt64((8.9 + 4.2 + 2.0) * g)
    system.memPressure = pressure
    system.swapUsedBytes = UInt64(swapGiB * g)
    if includeProcesses {
        // Mirrors the mock's DATA.memProcs (RSS, top-5).
        system.topProcesses = [
            MonitorProcessSample(name: "Xcode", cpuPercent: 22, memBytes: UInt64(3.4 * g)),
            MonitorProcessSample(name: "LiveWallpaper", cpuPercent: 9, memBytes: UInt64(1.7 * g)),
            MonitorProcessSample(name: "claude (Helper)", cpuPercent: 4, memBytes: UInt64(1.4 * g)),
            MonitorProcessSample(name: "Windows App (WPE)", cpuPercent: 12, memBytes: UInt64(1.1 * g)),
            MonitorProcessSample(name: "Safari", cpuPercent: 3, memBytes: UInt64(0.82 * g)),
        ]
    }

    var snapshot = MonitorSnapshot()
    snapshot.timestamp = Date().timeIntervalSince1970
    snapshot.system = system

    // A mostly-normal 120-sample run with one short warn blip near the middle
    // (mirrors the mock's `memHist`); M reads the trailing 60s of it, L the full
    // 120s. Category series roughly match the snapshot's AM split proportions.
    var used: [Double] = []
    var press: [String] = []
    var app: [Double] = [], wired: [Double] = [], compressed: [Double] = []
    for i in 0..<120 {
        let u = 0.40 + Double(i) / 120.0 * 0.08 + (i > 74 && i < 82 ? 0.10 : 0)
        used.append(u)
        press.append(i > 74 && i < 82 ? "warn" : "normal")
        app.append(u * 0.59)
        wired.append(u * 0.28)
        compressed.append(u * 0.13)
    }
    var history = MonitorHistorySnapshot()
    history.memUsedFraction = used
    history.memPressure = press
    history.memAppFraction = app
    history.memWiredFraction = wired
    history.memCompressedFraction = compressed

    return MonitorWidgetContext(
        snapshot: snapshot,
        history: history,
        placement: MonitorWidgetPlacement(kind: .memory, size: size, options: options),
        isEditing: false,
        isAgentFleetEnabled: false,
        reduceMotion: false,
        now: Date()
    )
}

// Preview frames are Apple's exact widget tiles: S 170×170, M 364×170, L 364×376.

#Preview("Memory · S") {
    HStack(spacing: 20) {
        MonitorMemoryWidgetView(context: memoryPreviewContext(size: .small, pressure: "normal", swapGiB: 0))
            .frame(width: 170, height: 170)
        MonitorMemoryWidgetView(context: memoryPreviewContext(size: .small, pressure: "warn", swapGiB: 2.4))
            .frame(width: 170, height: 170)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("Memory · M") {
    VStack(spacing: 20) {
        MonitorMemoryWidgetView(context: memoryPreviewContext(size: .medium, pressure: "normal"))
            .frame(width: 364, height: 170)
        MonitorMemoryWidgetView(context: memoryPreviewContext(size: .medium, pressure: "warn"))
            .frame(width: 364, height: 170)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("Memory · L") {
    HStack(alignment: .top, spacing: 20) {
        // Full L: curve + breakdown + top-by-memory.
        MonitorMemoryWidgetView(context: memoryPreviewContext(size: .large, pressure: "normal"))
            .frame(width: 364, height: 376)
        // No processes sampled + compact breakdown + showTopProcesses off —
        // exercises the `breakdown`/`showTopProcesses` option reads.
        MonitorMemoryWidgetView(context: memoryPreviewContext(
            size: .large, pressure: "warn", includeProcesses: false,
            options: ["breakdown": .string("compact"), "showTopProcesses": .bool(false)]))
            .frame(width: 364, height: 376)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}
#endif
