import SwiftUI
import LiveWallpaperCore

/// Disk I/O widget — the same mirrored-scope idiom as Network, hue-separated into
/// its own family (sage R grows up / violet-steel W grows down). S/M are ported
/// 1:1 from `.claude/plan/monitor-design/index.html` (`disk_s` / `disk_m`); the
/// board now hands every size Apple's fixed widget frame (S 170×170, M 364×170,
/// L 364×376 visible points).
///
///   S (1×1 cell): equal-size R/W rate rows (kind carried by hue + order, not
///            size) over the same mirrored dual-area scope M uses + recent R
///            peak, under an "ALL DISKS" source label.
///   M (2×1): a mirrored dual-area scope (`historyWindow` samples, 120 default —
///            matches the mock's `disk120`) + current R·W + corner R peak +
///            session Σ + sample freshness.
///   L (2×2): the mock explicitly cuts Disk's L ("I/O alone can't fill 4×4" —
///            capacity needs a separate Storage widget over `statfs`, out of scope
///            here). This is a same-system backfill, not a 1:1 mock port: the S
///            hero rate pair laid on one line, a taller history scope with both
///            R/W peaks pinned in its corners (S/M show R only), an R/W
///            session-split bar (`breakdown` option toggles its byte legend) with
///            freshness, and a "Top by I/O" per-app list (`topIOProcesses`,
///            demand-gated by the sampler; `showTopProcesses` option).
struct MonitorDiskWidgetView: View {
    let context: MonitorWidgetContext

    // Disk hue pair (mock `DISK_UP` / `DISK_DN`). Read = sage (== signalSage),
    // Write = violet-steel, deliberately distinct from Network's plain steel so
    // the two scopes never blur together.
    private static let readColor = MonitorDesign.signalSage
    private static let writeColor = MonitorDesign.oklch(0.62, 0.07, 288)
    /// The amber square that rides beside the peak tag (`.peaktag::before`).
    private static let peakSwatch = MonitorDesign.oklch(0.72, 0.09, 60)

    /// L's "Top by I/O" list cap (the sampler already ranks and caps its feed).
    private static let topIORowCap = 5

    private var sys: MonitorSystemSnapshot { context.snapshot.system ?? MonitorSystemSnapshot() }
    private var history: MonitorHistorySnapshot { context.history }

    var body: some View {
        GeometryReader { geo in
            // Mock type scale reads `cellH = cardHeight / rows`; S/M span one
            // board row and L two, so 2·rowSpan yields one near-constant cell
            // height (85 / 94 pt) — type stays glanceable, never balloons with
            // the fixed Apple frames (the same convention CPU uses).
            let rowSpan: CGFloat = context.placement.size == .large ? 2 : 1
            let cellHeight = geo.size.height / (2 * rowSpan)
            switch context.placement.size {
            case .small: small(cellHeight: cellHeight)
            case .medium: medium(cellHeight: cellHeight)
            case .large: large(cellHeight: cellHeight)
            }
        }
    }

    // MARK: - Small (1×1)

    private func small(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        return MonitorWidgetContainer(label: "Disk", cellHeight: cellHeight) {
            Text(verbatim: "ALL DISKS")
                .foregroundStyle(MonitorDesign.inkFaint)
        } content: {
            VStack(alignment: .leading, spacing: scale.label * 0.55) {
                dualRate(scale: scale, heroScale: 0.58)
                MirroredAreaChart(
                    up: Self.tail(history.diskRead, count: chartWindowSamples),
                    down: Self.tail(history.diskWrite, count: chartWindowSamples),
                    upColor: Self.readColor,
                    downColor: Self.writeColor
                )
                .frame(maxHeight: .infinity)
                .frame(minHeight: scale.caption * 2.4)
                Self.peakTag(label: String(localized: "R peak", comment: "Disk widget: recent read-rate peak label."),
                             value: MonitorFormat.rate(history.diskReadPeak),
                             scale: scale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// S's "current pair": R and W rows at ONE size — direction/kind is carried
    /// by the hue-coded letter and stacking order, never by size asymmetry.
    private func dualRate(scale: MonitorDesign.TypeScale, heroScale: CGFloat) -> some View {
        let size = scale.hero * heroScale
        return VStack(alignment: .leading, spacing: scale.label * 0.3) {
            heroRateItem(letter: "R", color: Self.readColor,
                         rate: history.currentRead(sys), size: size)
            heroRateItem(letter: "W", color: Self.writeColor,
                         rate: sys.diskWriteBytesPerSec, size: size)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// One hue-coded letter + hero-weight rate — the atom S stacks and L lays out
    /// in a row.
    private func heroRateItem(
        letter: String, color: Color, rate: Double, size: CGFloat
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.06) {
            Text(verbatim: letter)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Self.rateHero(rate, size: size)
        }
    }

    // MARK: - Medium (2×1)

    private func medium(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        return MonitorWidgetContainer(label: "Disk", cellHeight: cellHeight) {
            Text(verbatim: "ALL DISKS")
                .foregroundStyle(MonitorDesign.inkFaint)
        } content: {
            VStack(alignment: .leading, spacing: scale.label * 0.6) {
                currentPairRow(scale: scale)
                MirroredAreaChart(
                    up: Self.tail(history.diskRead, count: chartWindowSamples),
                    down: Self.tail(history.diskWrite, count: chartWindowSamples),
                    upColor: Self.readColor,
                    downColor: Self.writeColor
                )
                .frame(maxHeight: .infinity)
                .frame(minHeight: scale.caption * 3)
                .overlay(alignment: .topTrailing) {
                    // R peak pinned into the scope's own corner (mirrors CPU's M
                    // sparkline peak tag) instead of a separate row.
                    Self.peakTag(label: String(localized: "R peak", comment: "Disk widget: recent read-rate peak label."),
                                 value: MonitorFormat.rate(history.diskReadPeak),
                                 scale: scale)
                        .padding(scale.label * 0.3)
                }
                footerRow(scale: scale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// "R read  W write"  ↔  "readRate · writeRate".
    private func currentPairRow(scale: MonitorDesign.TypeScale) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(spacing: scale.label * 0.35) {
                legendKey("R", color: Self.readColor, size: scale.label)
                Text("read").foregroundStyle(MonitorDesign.inkFaint)
                legendKey("W", color: Self.writeColor, size: scale.label)
                    .padding(.leading, scale.label * 0.5)
                Text("write").foregroundStyle(MonitorDesign.inkFaint)
            }
            .font(MonitorDesign.labelFont(size: scale.label))
            .tracking(MonitorDesign.labelTracking(size: scale.label))
            .textCase(.uppercase)

            Spacer(minLength: 4)

            HStack(spacing: scale.caption * 0.35) {
                Text(verbatim: MonitorFormat.rate(sys.diskReadBytesPerSec))
                    .foregroundStyle(MonitorDesign.inkPrimary)
                Text(verbatim: "·").foregroundStyle(MonitorDesign.inkFaint)
                Text(verbatim: MonitorFormat.rate(sys.diskWriteBytesPerSec))
                    .foregroundStyle(MonitorDesign.inkPrimary)
            }
            .font(.system(size: scale.caption, weight: .semibold, design: .rounded))
            .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// "Σ <total> · <age> ago" — the R peak now lives in the chart's own corner
    /// (see `medium`'s overlay), so this row is just the session micro-tag.
    private func footerRow(scale: MonitorDesign.TypeScale) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Spacer(minLength: 0)
            Text(verbatim: sessionSummary)
                .font(MonitorDesign.labelFont(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monitorChip(scale)
        }
    }

    private var sessionSummary: String {
        let total = history.diskReadSessionBytes + history.diskWriteSessionBytes
        var s = "Σ " + MonitorFormat.bytes(total)
        if let age = freshnessSeconds {
            // "ago" is the only word here; the Σ total and age are data/notation.
            s += " · " + MonitorFormat.ago(age) + " "
                + String(localized: "ago", comment: "Relative-age suffix, e.g. '2m ago'.")
        }
        return s
    }

    /// Seconds since the most recent sample; nil when there's no history yet.
    private var freshnessSeconds: Double? {
        guard let last = history.sampleTimes.last else { return nil }
        return max(0, context.now.timeIntervalSince1970 - last)
    }

    // MARK: - Settings (placement.options; read-side only)
    //
    // The mock has no bespoke Disk settings popover (unlike CPU/Memory/GPU) — these
    // options are a same-system backfill, keyed to match Memory's already-landed
    // convention (`historyWindow` seconds, `breakdown` full/compact, boolean
    // `showTopProcesses`) so the shared popover reads every widget the same way.
    // Popover UI wiring is NOT part of this file — see
    // `MonitorWidgetSettingsPopover.swift` / the task report.

    /// `historyWindow` (seconds ≈ samples at the board's ~1Hz cadence) trims the
    /// mirrored scope's trailing window (every size). Absent/invalid ⇒ 120, matching the
    /// mock's `disk120` (M already shows the full window, unlike Network's
    /// shrunk-for-M `net60`) — the setting only narrows, never surprises.
    private var chartWindowSamples: Int {
        Self.historyWindowSamples(
            optionSeconds: context.placement.options["historyWindow"]?.numberValue,
            fallbackSeconds: 120)
    }

    /// `breakdown` ("compact" hides the L split-bar's R/W byte legend, keeping just
    /// the proportion bar) — same key/semantics as Memory's AM-bar toggle.
    private var splitLegendCompact: Bool {
        Self.breakdownIsCompact(context.placement.options["breakdown"]?.stringValue)
    }

    /// `showTopProcesses` (default true — the shared settings-popover key Memory's
    /// L list already reads) gates the L "Top by I/O" section.
    private var showsTopProcesses: Bool {
        Self.showsTopProcesses(context.placement.options["showTopProcesses"]?.boolValue)
    }

    /// L's "Top by I/O" feed: the sampler's per-app, read+write-ranked list, kept
    /// only when the option allows it. The sampler produces it on demand (Disk
    /// widget on the board) and rates need one warm-up tick, so nil/empty just
    /// means "no section yet".
    private var topIOProcesses: [MonitorProcessSample] {
        guard showsTopProcesses, let procs = sys.topIOProcesses else { return [] }
        return Array(procs.prefix(Self.topIORowCap))
    }

    // MARK: - Large (2×2)
    //
    // A same-system backfill (see type doc) — not a 1:1 mock port. Leads with the
    // S hero pair on one line (a 376-pt card whose "now" read is caption-size would
    // invert the hierarchy), then spends the height on real fields S/M already read
    // but have no room to show: the W peak (S/M show R only), a session R/W split
    // rendered as a proportion bar (Memory's Activity-Monitor breakdown bar, sized
    // down to two segments), and — now that `topIOProcesses` carries real per-app
    // rusage attribution — a "Top by I/O" list in Memory's L-list idiom. When the
    // list is present the scope's flexible floor compresses so every fixed row
    // still fits the 331-pt content budget.

    private func large(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let topIO = topIOProcesses
        return MonitorWidgetContainer(label: "Disk", cellHeight: cellHeight) {
            Text(verbatim: "ALL DISKS")
                .foregroundStyle(MonitorDesign.inkFaint)
        } content: {
            VStack(alignment: .leading, spacing: scale.label * 0.6) {
                heroPairRow(scale: scale)
                historySectionLabel(scale: scale)
                MirroredAreaChart(
                    up: Self.tail(history.diskRead, count: chartWindowSamples),
                    down: Self.tail(history.diskWrite, count: chartWindowSamples),
                    upColor: Self.readColor,
                    downColor: Self.writeColor
                )
                .frame(maxHeight: .infinity)
                .frame(minHeight: scale.caption * (topIO.isEmpty ? 5 : 3))
                .overlay(alignment: .topTrailing) {
                    // R grows up / W grows down in this mirrored scope, so their
                    // peak tags pin to the matching corner instead of a row below.
                    Self.peakTag(label: String(localized: "R peak", comment: "Disk widget: recent read-rate peak label."),
                                 value: MonitorFormat.rate(history.diskReadPeak), scale: scale)
                        .padding(scale.label * 0.3)
                }
                .overlay(alignment: .bottomTrailing) {
                    Self.peakTag(label: String(localized: "W peak", comment: "Disk widget: recent write-rate peak label."),
                                 value: MonitorFormat.rate(history.diskWritePeak), scale: scale)
                        .padding(scale.label * 0.3)
                }
                sessionSectionLabel(scale: scale)
                DiskSplitBar(
                    readFraction: sessionSplit.read,
                    writeFraction: sessionSplit.write,
                    readColor: Self.readColor,
                    writeColor: Self.writeColor
                )
                .frame(height: max(6, scale.caption * 1.05))
                sessionFooterRow(scale: scale)
                if !topIO.isEmpty {
                    topIOBlock(topIO, scale: scale)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// "Top by I/O" — the sampler's per-app disk ranking in Memory's L-list idiom
    /// (bullet + truncating name + right-aligned numeric columns). Section label is
    /// verbatim like this file's other axis labels (ALL DISKS / R peak's chip text).
    private func topIOBlock(
        _ procs: [MonitorProcessSample], scale: MonitorDesign.TypeScale
    ) -> some View {
        VStack(alignment: .leading, spacing: scale.caption * 0.32) {
            Text(verbatim: "TOP BY I/O")
                .font(MonitorDesign.labelFont(size: scale.label))
                .tracking(MonitorDesign.labelTracking(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
            ForEach(Array(procs.enumerated()), id: \.offset) { _, proc in
                topIORow(proc, scale: scale)
            }
        }
    }

    private func topIORow(
        _ proc: MonitorProcessSample, scale: MonitorDesign.TypeScale
    ) -> some View {
        HStack(spacing: scale.caption * 0.8) {
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
            ioRateColumn(letter: "R", color: Self.readColor,
                         rate: proc.ioReadBytesPerSec ?? 0, scale: scale)
            ioRateColumn(letter: "W", color: Self.writeColor,
                         rate: proc.ioWriteBytesPerSec ?? 0, scale: scale)
        }
    }

    /// One hue-lettered rate column (the widget's R/W letter idiom, matching the
    /// mirrored scope's up/down assignment). The value sits right-aligned in a
    /// FIXED width sized for `MonitorFormat.rate`'s widest output ("999.9 KB/s"),
    /// so the rightmost column never clips — the name column truncates instead.
    private func ioRateColumn(
        letter: String, color: Color, rate: Double, scale: MonitorDesign.TypeScale
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.caption * 0.3) {
            Text(verbatim: letter)
                .font(.system(size: scale.caption * 0.86, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(verbatim: MonitorFormat.rate(rate))
                .font(MonitorDesign.subFont(size: scale.caption * 0.94)).monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: scale.caption * 5.3, alignment: .trailing)
        }
    }

    /// L's "now" read: both current rates at hero weight on one baseline, letters
    /// hue-coded — the same atom S stacks vertically, laid flat where L has width.
    private func heroPairRow(scale: MonitorDesign.TypeScale) -> some View {
        let size = scale.hero * 0.58
        return HStack(alignment: .firstTextBaseline, spacing: size) {
            heroRateItem(letter: "R", color: Self.readColor,
                         rate: history.currentRead(sys), size: size)
            heroRateItem(letter: "W", color: Self.writeColor,
                         rate: sys.diskWriteBytesPerSec, size: size)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func historySectionLabel(scale: MonitorDesign.TypeScale) -> some View {
        // Window length is set silently via settings, not printed here (the board
        // convention: a section title names the content, not its sample count).
        Text("History", comment: "Disk widget: L card's history-chart section label.")
            .font(MonitorDesign.labelFont(size: scale.label))
            .tracking(MonitorDesign.labelTracking(size: scale.label))
            .textCase(.uppercase)
            .foregroundStyle(MonitorDesign.inkFaint)
    }

    private func sessionSectionLabel(scale: MonitorDesign.TypeScale) -> some View {
        Text("Session", comment: "Disk widget: L card's R/W session-split section label.")
            .font(MonitorDesign.labelFont(size: scale.label))
            .tracking(MonitorDesign.labelTracking(size: scale.label))
            .textCase(.uppercase)
            .foregroundStyle(MonitorDesign.inkFaint)
    }

    /// Split-bar byte legend + sample freshness merged onto one line, so L's fixed
    /// 331-pt content budget goes to the scope instead of stacked micro-rows. The
    /// `breakdown: compact` option drops the legend; the bar alone still carries
    /// the true proportions.
    private func sessionFooterRow(scale: MonitorDesign.TypeScale) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !splitLegendCompact {
                HStack(spacing: scale.label * 1.4) {
                    splitLegendItem(letter: "R", color: Self.readColor,
                                     bytes: history.diskReadSessionBytes, scale: scale)
                    splitLegendItem(letter: "W", color: Self.writeColor,
                                     bytes: history.diskWriteSessionBytes, scale: scale)
                }
                .monitorChip(scale)
            }
            Spacer(minLength: 6)
            if let age = freshnessSeconds {
                Text(verbatim: MonitorFormat.ago(age) + " "
                     + String(localized: "ago", comment: "Relative-age suffix, e.g. '2m ago'."))
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func splitLegendItem(
        letter: String, color: Color, bytes: Double, scale: MonitorDesign.TypeScale
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.label * 0.3) {
            Text(verbatim: letter)
                .font(.system(size: scale.label, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(verbatim: MonitorFormat.bytes(bytes))
                .font(MonitorDesign.subFont(size: scale.label)).monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
        }
    }

    /// R/W fractions of the session Σ (each 0…1, summing to 1; both 0 pre-session).
    private var sessionSplit: (read: Double, write: Double) {
        Self.splitFractions(readBytes: history.diskReadSessionBytes,
                             writeBytes: history.diskWriteSessionBytes)
    }

    // MARK: - Shared pieces

    private func legendKey(_ text: String, color: Color, size: CGFloat) -> some View {
        Text(verbatim: text)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(color)
    }

    // MARK: - Static helpers (testable, chrome-free)

    /// Rate rendered with the value at hero weight and the unit whispered small
    /// (mock `rateHero` → `.hero .u`).
    static func rateHero(_ bytesPerSec: Double, size: CGFloat) -> some View {
        let text = MonitorFormat.rate(bytesPerSec)
        let parts = text.split(separator: " ", maxSplits: 1)
        let value = String(parts.first ?? "")
        let unit = parts.count > 1 ? String(parts[1]) : ""
        return HStack(alignment: .firstTextBaseline, spacing: size * 0.04) {
            Text(verbatim: value)
                .font(MonitorDesign.heroFont(size: size)).monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
            if !unit.isEmpty {
                Text(verbatim: unit)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitorDesign.inkFaint)
            }
        }
    }

    /// Recent-peak tag: a small amber swatch + tracked label + tabular value,
    /// contained in the board-wide annotation chip (`monitorChip`).
    static func peakTag(label: String, value: String, scale: MonitorDesign.TypeScale) -> some View {
        let size = scale.label
        return HStack(alignment: .firstTextBaseline, spacing: size * 0.35) {
            RoundedRectangle(cornerRadius: 1)
                .fill(peakSwatch.opacity(0.85))
                .frame(width: size * 0.5, height: size * 0.5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size * 0.08 }
            Text(verbatim: label)
                .font(MonitorDesign.labelFont(size: size))
                .tracking(MonitorDesign.labelTracking(size: size))
                .textCase(.uppercase)
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: value)
                .font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
        }
        .lineLimit(1)
        .monitorChip(scale)
    }

    /// Last `count` samples of a series (never fewer than the series has) — the
    /// M/L chart's `historyWindow` windowing (mirrors `MonitorNetworkWidgetView`).
    nonisolated static func tail(_ series: [Double], count: Int) -> [Double] {
        guard series.count > count else { return series }
        return Array(series.suffix(count))
    }

    /// Resolve the `historyWindow` option (seconds) against a fallback. A non-
    /// finite/non-positive override is ignored; the sample floor is 2 — same shape
    /// as `MonitorMemoryWidgetView.historyWindowSamples`, the emerging fleet-wide
    /// `historyWindow` option convention.
    nonisolated static func historyWindowSamples(optionSeconds: Double?, fallbackSeconds: Int) -> Int {
        guard let optionSeconds, optionSeconds.isFinite, optionSeconds > 0 else {
            return fallbackSeconds
        }
        return max(2, Int(optionSeconds.rounded()))
    }

    /// `breakdown` option: only the literal `"compact"` collapses a legend; absent
    /// or anything else is the full/default state. Same semantics as Memory's.
    nonisolated static func breakdownIsCompact(_ raw: String?) -> Bool { raw == "compact" }

    /// `showTopProcesses` option: absent ⇒ shown (the popover default `on`) —
    /// same shape as `MonitorMemoryWidgetView.showsTopProcesses`.
    nonisolated static func showsTopProcesses(_ raw: Bool?) -> Bool { raw ?? true }

    /// R/W fractions of `readBytes + writeBytes` (each clamped ≥0 first). Both 0
    /// when the total is 0 — never divides by zero, never fabricates a 50/50 split.
    nonisolated static func splitFractions(
        readBytes: Double, writeBytes: Double
    ) -> (read: Double, write: Double) {
        let r = readBytes.isFinite ? max(readBytes, 0) : 0
        let w = writeBytes.isFinite ? max(writeBytes, 0) : 0
        let total = r + w
        guard total > 0 else { return (0, 0) }
        return (r / total, w / total)
    }
}

// MARK: - Session split bar

/// Two-segment proportion bar (R left, W right) of the session Σ — the same
/// track/segment idiom as Memory's Activity-Monitor breakdown bar, sized down to
/// two series. A segment under the ~0.4% floor is skipped so a near-zero side
/// doesn't render a stray sliver.
private struct DiskSplitBar: View {
    var readFraction: Double
    var writeFraction: Double
    var readColor: Color
    var writeColor: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                if readFraction > 0.004 {
                    readColor.opacity(0.85)
                        .frame(width: max(1, w * CGFloat(readFraction)))
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(MonitorDesign.bg0.opacity(0.55)).frame(width: 1)
                        }
                }
                if writeFraction > 0.004 {
                    writeColor.opacity(0.85)
                        .frame(width: max(1, w * CGFloat(writeFraction)))
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

private extension MonitorHistorySnapshot {
    /// Current read rate — the freshest history sample if present, else the live
    /// snapshot value (keeps S and M reading identically to the mock's `sys.*`).
    func currentRead(_ sys: MonitorSystemSnapshot) -> Double {
        diskRead.last ?? sys.diskReadBytesPerSec
    }
}

// MARK: - Previews

#if DEBUG
private func diskMockContext(size: MonitorWidgetSize) -> MonitorWidgetContext {
    let mib = 1_048_576.0
    let reads = [8, 14, 22, 31, 18, 12, 26, 40, 28, 16, 11, 24, 38, 22, 14, 9, 27, 35, 20, 23]
        .map { Double($0) * mib }
    let writes = [2, 3, 5, 4, 3, 6, 8, 5, 4, 3, 2, 4, 7, 5, 3, 2, 5, 6, 4, 3]
        .map { Double($0) * mib }
    var history = MonitorHistorySnapshot()
    history.diskRead = reads
    history.diskWrite = writes
    history.sampleTimes = (0..<reads.count).map { Date().timeIntervalSince1970 - Double(reads.count - $0) }
    history.diskReadPeak = reads.max() ?? 0
    history.diskWritePeak = writes.max() ?? 0
    history.diskReadSessionBytes = 4.2 * 1_073_741_824
    history.diskWriteSessionBytes = 1.1 * 1_073_741_824

    var system = MonitorSystemSnapshot()
    system.diskReadBytesPerSec = reads.last ?? 0
    system.diskWriteBytesPerSec = writes.last ?? 0
    system.topIOProcesses = [
        MonitorProcessSample(name: "Xcode", cpuPercent: 34, memBytes: 3_100_000_000,
                             ioReadBytesPerSec: 18.4 * mib, ioWriteBytesPerSec: 2.1 * mib),
        MonitorProcessSample(name: "Time Machine", cpuPercent: 4, memBytes: 220_000_000,
                             ioReadBytesPerSec: 3.2 * mib, ioWriteBytesPerSec: 11.6 * mib),
        MonitorProcessSample(name: "Spotlight", cpuPercent: 7, memBytes: 310_000_000,
                             ioReadBytesPerSec: 5.8 * mib, ioWriteBytesPerSec: 0.4 * mib),
        MonitorProcessSample(name: "Safari", cpuPercent: 12, memBytes: 1_900_000_000,
                             ioReadBytesPerSec: 1.1 * mib, ioWriteBytesPerSec: 0.9 * mib)
    ]

    var snapshot = MonitorSnapshot()
    snapshot.timestamp = Date().timeIntervalSince1970
    snapshot.system = system

    return MonitorWidgetContext(
        snapshot: snapshot,
        history: history,
        placement: MonitorWidgetPlacement(kind: .disk, size: size),
        isEditing: false,
        isAgentFleetEnabled: false,
        reduceMotion: false,
        now: Date()
    )
}

// Preview frames are Apple's exact visible widget sizes (HIG Widgets →
// Specifications), the same frames `MonitorBoardGeometry` renders on the board.

#Preview("Disk · S (170×170)") {
    MonitorDiskWidgetView(context: diskMockContext(size: .small))
        .frame(width: 170, height: 170)
        .padding(28)
        .background(MonitorDesign.boardWash)
}

#Preview("Disk · M (364×170)") {
    MonitorDiskWidgetView(context: diskMockContext(size: .medium))
        .frame(width: 364, height: 170)
        .padding(28)
        .background(MonitorDesign.boardWash)
}

#Preview("Disk · L (364×376)") {
    MonitorDiskWidgetView(context: diskMockContext(size: .large))
        .frame(width: 364, height: 376)
        .padding(28)
        .background(MonitorDesign.boardWash)
}
#endif
