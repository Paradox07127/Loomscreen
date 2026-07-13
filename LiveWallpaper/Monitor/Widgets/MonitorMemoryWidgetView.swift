import SwiftUI
import LiveWallpaperCore

/// Native 1:1 replica of the Memory widget from the approved design
/// (`.claude/plan/monitor-design/index.html`, `buildMemorySection`).
///
/// Hero read = memory **pressure** (a discrete state), never "% used" — Apple's
/// own stance: free RAM ≠ fast (memory-verdict ④). The tank's liquid level is
/// used%, but its tint follows *pressure*, not level. `memUsedBytes` is already
/// the Activity-Monitor formula (App + Wired + Compressed; Cached Files excluded),
/// so it matches what the user sees in Activity Monitor.
///
/// - S (2×2): a vertical tank (level = used%, tint = pressure) beside the pressure
///   state as the hero read, used% as context, and a swap chip when relevant.
/// - M (4×2): used/total hero + pressure chip, the Activity-Monitor breakdown bar
///   (App/Wired/Compressed/Cached Files/Swap), a valued legend, and a ~60s used%
///   micro-trend whose stroke is coloured per discrete pressure segment.
/// - L (4×4, `mem_l`): NO tank. Hero + pressure chip + swap caption on one row,
///   then the SAME merged curve widened to a ~120s window with a normal/warn/crit
///   swatch legend, the AM breakdown (bar + legend), and a "Top by memory" RSS
///   list (`topProcesses` re-ranked by `memBytes`, top-5) — the two M charts fold
///   into one hero visual and the extra height buys a process ranking, never
///   bigger type (SPEC §3.0 3-size-cap).
struct MonitorMemoryWidgetView: View {
    let context: MonitorWidgetContext

    private var system: MonitorSystemSnapshot? { context.snapshot.system }
    private var pressure: MonitorPressure {
        MonitorMemoryWidgetView.pressure(system?.memPressure)
    }

    var body: some View {
        GeometryReader { geo in
            let cellHeight = geo.size.height
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

    // MARK: - S (2×2): tank + pressure hero

    @ViewBuilder
    private func small(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let usedFraction = memUsedFraction
        HStack(alignment: .center, spacing: 10) {
            TankGauge(level: usedFraction, pressure: pressure,
                      cornerRadius: max(6, cellHeight * 0.06))
                .frame(width: 40)
                .overlay(alignment: .topTrailing) {
                    // used% caption riding just inside the tank top-right
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(verbatim: "\(usedPercentInt)")
                        Text(verbatim: "%")
                            .font(MonitorDesign.captionFont(size: scale.caption * 0.62))
                            .foregroundStyle(MonitorDesign.inkFaint)
                    }
                    .font(MonitorDesign.subFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkMuted)
                    .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
                    .padding(4)
                }

            VStack(alignment: .leading, spacing: 3) {
                Spacer(minLength: 0)
                // PRESSURE is the hero read. The word (Normal/Warning/Critical) is
                // localized via the app's existing catalog keys.
                Text(MonitorMemoryWidgetView.pressureDisplayKey(pressure))
                    .font(MonitorDesign.heroFont(size: scale.hero * 0.62))
                    .foregroundStyle(pressureHeroColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(verbatim: "PRESSURE")
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(MonitorDesign.labelTracking(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
                // used% integrates as context, not the hero. The "%" is notation
                // (verbatim); "used" is a word (localized).
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: "\(usedPercentInt)%")
                        .foregroundStyle(MonitorDesign.inkMuted)
                    Text("used")
                        .font(MonitorDesign.captionFont(size: scale.sub * 0.62))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
                .font(MonitorDesign.subFont(size: scale.sub * 0.9))
                .monospacedDigit()
                .padding(.top, 1)
                if showsSwap {
                    // "Swap" reuses the app's existing catalog key; the "N.NG"
                    // figure is data (verbatim).
                    (Text("Swap") + Text(verbatim: " \(swapGiBString)G"))
                        .font(MonitorDesign.labelFont(size: scale.label))
                        .tracking(scale.label * 0.06)
                        .foregroundStyle(MonitorDesign.signalSteel)
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
                PressureChip(pressure: pressure, labelSize: scale.label)
            }

            breakdownBlock(scale: scale)

            // Used% micro-trend (window size from the `historyWindow` option,
            // default 60s), stroke coloured per discrete pressure segment.
            HStack {
                Text(verbatim: "USED · \(pressureWindowSamples)s")
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(MonitorDesign.labelTracking(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
                Spacer()
                Text("colour = pressure")
                    .font(MonitorDesign.captionFont(size: scale.label * 0.92))
                    .foregroundStyle(MonitorDesign.inkFaint.opacity(0.85))
            }
            PressureCurve(
                used: recentUsed,
                pressure: recentPressure,
                reduceMotion: context.reduceMotion
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
                HStack(spacing: 8) {
                    PressureChip(pressure: pressure, labelSize: scale.label)
                    if showsSwap {
                        swapCaption(scale: scale)
                    }
                }
            }

            // The merged pressure-coloured used% curve, widened to `historyWindow`
            // (default 120s at L) with a normal/warn/crit swatch legend.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 4) {
                        Text(verbatim: "USED% · \(pressureWindowSamples)s")
                            .font(MonitorDesign.labelFont(size: scale.label))
                            .tracking(MonitorDesign.labelTracking(size: scale.label))
                            .foregroundStyle(MonitorDesign.inkFaint)
                        Text("colour = pressure")
                            .font(MonitorDesign.captionFont(size: scale.label * 0.92))
                            .foregroundStyle(MonitorDesign.inkFaint.opacity(0.85))
                    }
                    Spacer()
                    PressureLegend(labelSize: scale.label)
                }
                PressureCurve(
                    used: recentUsed,
                    pressure: recentPressure,
                    reduceMotion: context.reduceMotion
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 46)
            }
            .frame(minHeight: 66)

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
    }

    /// The Activity-Monitor breakdown bar + valued legend, shared by M and L.
    /// The legend is omitted in "compact" mode (`breakdown` option) — the bar
    /// alone still carries the true proportions, just without the per-segment
    /// GiB readout.
    @ViewBuilder
    private func breakdownBlock(scale: MonitorDesign.TypeScale, headerLabel: String? = nil) -> some View {
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
                    MemoryBreakdownLegend(segments: segments, labelSize: scale.label)
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

    /// Most-recent samples of the used fraction for the M/L trend, sized by
    /// `pressureWindowSamples` (M defaults to 60, L to 120 — mock `mem_m`/`mem_l`).
    private var recentUsed: [Double] {
        Array(context.history.memUsedFraction.suffix(pressureWindowSamples))
    }

    /// Pressure levels aligned to `recentUsed` (same suffix window).
    private var recentPressure: [Int] {
        Array(context.history.memPressure.suffix(pressureWindowSamples))
            .map { MonitorMemoryWidgetView.pressureLevel($0) }
    }

    /// The `historyWindow` widget option (seconds), resolved against a
    /// size-specific default. The board samples at ~1Hz, so seconds ≈ samples —
    /// the same simplifying assumption every other Monitor widget's trend label
    /// already makes. (Field contract: mock index.html:3641 `Memory{historyWindow}`.)
    private var pressureWindowSamples: Int {
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

    /// Discrete level for the pressure-coloured curve (0 normal / 1 warn / 2 crit).
    nonisolated static func pressureLevel(_ raw: String?) -> Int {
        switch pressure(raw) {
        case .normal: return 0
        case .warn: return 1
        case .critical: return 2
        }
    }

    nonisolated static func pressureLabel(_ p: MonitorPressure) -> String {
        switch p {
        case .normal: return "normal"
        case .warn: return "warning"
        case .critical: return "critical"
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

    /// Split a used% curve into runs of constant pressure. Each run shares its
    /// boundary sample with the next so the line stays continuous but the colour
    /// switch is crisp (mock's `pressureCurveChart` per-segment idiom). Returns
    /// index ranges into `used` paired with the pressure level for that run.
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
    var labelSize: CGFloat

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
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(chipFill)
                .overlay(Capsule().strokeBorder(chipStroke, lineWidth: 1))
        )
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

    private var chipFill: Color {
        switch pressure {
        case .normal: return MonitorDesign.oklch(0.28, 0.03, 158, alpha: 0.24)
        case .warn: return MonitorDesign.oklch(0.30, 0.05, 44, alpha: 0.28)
        case .critical: return MonitorDesign.oklch(0.32, 0.06, 34, alpha: 0.30)
        }
    }

    private var chipStroke: Color {
        switch pressure {
        case .normal: return MonitorDesign.oklch(0.44, 0.07, 158, alpha: 0.60)
        case .warn: return MonitorDesign.oklch(0.50, 0.11, 44, alpha: 0.75)
        case .critical: return MonitorDesign.oklch(0.50, 0.13, 34, alpha: 0.80)
        }
    }
}

/// The shared normal/warn/crit stroke tones — one source of truth for the M/L
/// curve (`PressureCurve`) and the L legend swatches (`PressureLegend`), ported
/// 1:1 from the mock's `PCURVE` array.
private enum PressureTone {
    static let colors: [Color] = [
        MonitorDesign.oklch(0.82, 0.09, 158),   // normal → sage
        MonitorDesign.oklch(0.83, 0.135, 78),   // warn   → amber
        MonitorDesign.oklch(0.72, 0.16, 34),    // crit   → coral
    ]

    static func color(_ p: MonitorPressure) -> Color {
        switch p {
        case .normal: return colors[0]
        case .warn: return colors[1]
        case .critical: return colors[2]
        }
    }
}

/// The L curve's normal/warn/crit swatch legend (mock's `.pbleg`) — so the
/// per-segment colour coding is self-explaining beside the merged curve.
/// Labels reuse the existing "Normal"/"Warning"/"Critical" catalog keys
/// (the mock's abbreviated "warn"/"crit" would need new strings).
private struct PressureLegend: View {
    var labelSize: CGFloat

    private static let states: [MonitorPressure] = [.normal, .warn, .critical]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Self.states.enumerated()), id: \.offset) { _, state in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(PressureTone.color(state))
                        .frame(width: labelSize * 0.6, height: labelSize * 0.6)
                    Text(MonitorMemoryWidgetView.pressureDisplayKey(state))
                        .font(MonitorDesign.captionFont(size: labelSize * 0.94))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
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

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
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
/// gradient (same tone family as the AM breakdown's "App" slice), and the GiB
/// readout. Bar length is this row's RSS ÷ the busiest shown row's RSS.
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
            .frame(width: scale.caption * 3.6, height: scale.caption * 0.42)

            Text(verbatim: gib(proc.memBytes))
                .font(MonitorDesign.subFont(size: scale.caption * 0.94))
                .monospacedDigit()
                .foregroundStyle(AMSegmentStyle.legendColor(.app))
                .frame(width: scale.caption * 2.3, alignment: .trailing)
        }
    }

    private func gib(_ bytes: UInt64) -> String {
        String(format: "%.1fG", MonitorFormat.gib(Double(bytes)))
    }
}

// MARK: - Pressure-coloured used% curve (M + L trend)

/// A single used% curve whose height is used% (continuous) and whose stroke colour
/// is the discrete pressure level in effect at each instant — cut into per-pressure
/// runs sharing boundary vertices (mock's `pressureCurveChart`). Soft area fill per
/// run; a now-dot marks the head coloured to the current pressure. Shared by M
/// (60s default window) and L (120s default window) — only the window length
/// and the surrounding chrome (swatch legend at L) differ.
private struct PressureCurve: View {
    var used: [Double]
    /// Pressure level per sample (0 normal / 1 warn / 2 crit), aligned to `used`.
    var pressure: [Int]
    var reduceMotion: Bool

    private static let strokeColors: [Color] = PressureTone.colors
    private static let fillOpacity: [Double] = [0.26, 0.34, 0.40]

    private func level(_ i: Int) -> Int {
        guard i < pressure.count else { return 0 }
        return min(2, max(0, pressure[i]))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if used.count >= 2 {
                let pts = points(w: w, h: h)
                let runs = MonitorMemoryWidgetView.pressureRuns(count: used.count) { level($0) }
                ZStack {
                    baseline(w: w, h: h)
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        let slice = Array(pts[run.range])
                        let lv = run.level
                        areaPath(slice, height: h)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Self.strokeColors[lv].opacity(Self.fillOpacity[lv]),
                                        Self.strokeColors[lv].opacity(0.02),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                        linePath(slice)
                            .stroke(Self.strokeColors[lv],
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    if let last = pts.last {
                        let lv = level(used.count - 1)
                        Circle()
                            .fill(Self.strokeColors[lv])
                            .frame(width: 6, height: 6)
                            .position(last)
                            .shadow(color: Self.strokeColors[lv].opacity(0.6), radius: 3)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: used)
            } else {
                baseline(w: w, h: h)
            }
        }
    }

    private func points(w: CGFloat, h: CGFloat) -> [CGPoint] {
        let n = used.count
        guard n >= 2 else { return [] }
        // Used% is a fixed 0…1 axis with a little vertical inset (honest, stable).
        let inset: CGFloat = 4
        return used.enumerated().map { i, v in
            let x = CGFloat(i) / CGFloat(n - 1) * w
            let f = min(1, max(0, v))
            let y = h - CGFloat(f) * (h - inset * 2) - inset
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        var p = Path(); p.addLines(pts); return p
    }

    private func areaPath(_ pts: [CGPoint], height: CGFloat) -> Path {
        var p = Path()
        guard let first = pts.first, let last = pts.last else { return p }
        p.move(to: CGPoint(x: first.x, y: height))
        p.addLines(pts)
        p.addLine(to: CGPoint(x: last.x, y: height))
        p.closeSubpath()
        return p
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
    // (mirrors the mock's `memHist`); M reads the trailing 60s of it, L the full 120s.
    var used: [Double] = []
    var press: [String] = []
    for i in 0..<120 {
        used.append(0.40 + Double(i) / 120.0 * 0.08 + (i > 74 && i < 82 ? 0.10 : 0))
        press.append(i > 74 && i < 82 ? "warn" : "normal")
    }
    var history = MonitorHistorySnapshot()
    history.memUsedFraction = used
    history.memPressure = press

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

#Preview("Memory · S") {
    HStack(spacing: 20) {
        MonitorMemoryWidgetView(context: memoryPreviewContext(size: .small, pressure: "normal", swapGiB: 0))
            .frame(width: 150, height: 150)
        MonitorMemoryWidgetView(context: memoryPreviewContext(size: .small, pressure: "warn", swapGiB: 2.4))
            .frame(width: 150, height: 150)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("Memory · M") {
    VStack(spacing: 20) {
        MonitorMemoryWidgetView(context: memoryPreviewContext(size: .medium, pressure: "normal"))
            .frame(width: 320, height: 150)
        MonitorMemoryWidgetView(context: memoryPreviewContext(size: .medium, pressure: "warn"))
            .frame(width: 320, height: 150)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("Memory · L") {
    HStack(alignment: .top, spacing: 20) {
        // Full L: curve + breakdown + top-by-memory.
        MonitorMemoryWidgetView(context: memoryPreviewContext(size: .large, pressure: "normal"))
            .frame(width: 378, height: 392)
        // No processes sampled + compact breakdown + showTopProcesses off —
        // exercises the `breakdown`/`showTopProcesses` option reads.
        MonitorMemoryWidgetView(context: memoryPreviewContext(
            size: .large, pressure: "warn", includeProcesses: false,
            options: ["breakdown": .string("compact"), "showTopProcesses": .bool(false)]))
            .frame(width: 378, height: 392)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}
#endif
