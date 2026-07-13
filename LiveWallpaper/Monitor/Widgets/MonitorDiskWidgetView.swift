import SwiftUI
import LiveWallpaperCore

/// Disk I/O widget — the same mirrored-scope idiom as Network, hue-separated into
/// its own family (sage R grows up / violet-steel W grows down). S/M are ported
/// 1:1 from `.claude/plan/monitor-design/index.html` (`disk_s` / `disk_m`).
///
///   S (2×2): current R/W rate rows + a 30s micro-bar strip + recent R peak,
///            under an "ALL DISKS" source label.
///   M (4×2): a mirrored dual-area scope (`historyWindow` samples, 120 default —
///            matches the mock's `disk120`) + current R·W + R peak + session Σ
///            + sample freshness.
///   L (4×4): the mock explicitly cuts Disk's L ("I/O alone can't fill 4×4" —
///            capacity needs a separate Storage widget over `statfs`, out of scope
///            here). This is a same-system backfill — analogous to Memory's real L
///            (breakdown bar + legend, `historyWindow` option), not a 1:1 mock
///            port: the M current-pair row, a taller history scope, an R/W
///            session-split bar (`breakdown` option toggles its byte legend), and
///            both R/W peaks (S/M show R only) + freshness. Nothing fabricated —
///            every field is one S/M already reads (rate, history, peaks, session Σ).
struct MonitorDiskWidgetView: View {
    let context: MonitorWidgetContext

    // Disk hue pair (mock `DISK_UP` / `DISK_DN`). Read = sage (== signalSage),
    // Write = violet-steel, deliberately distinct from Network's plain steel so
    // the two scopes never blur together.
    private static let readColor = MonitorDesign.signalSage
    private static let writeColor = MonitorDesign.oklch(0.62, 0.07, 288)
    /// The amber square that rides beside the peak tag (`.peaktag::before`).
    private static let peakSwatch = MonitorDesign.oklch(0.72, 0.09, 60)

    /// 30s micro-strip width in the S card — tail of the read history.
    private static let microStripCount = 20

    private var sys: MonitorSystemSnapshot { context.snapshot.system ?? MonitorSystemSnapshot() }
    private var history: MonitorHistorySnapshot { context.history }

    var body: some View {
        switch context.placement.size {
        case .small:
            small
        case .medium:
            medium
        case .large:
            large
        }
    }

    // MARK: - Small (2×2)

    private var small: some View {
        GeometryReader { geo in
            let scale = MonitorDesign.TypeScale(cellHeight: geo.size.height)
            MonitorWidgetContainer(label: "Disk", cellHeight: geo.size.height) {
                Text(verbatim: "ALL DISKS")
                    .foregroundStyle(MonitorDesign.inkFaint)
            } content: {
                VStack(alignment: .leading, spacing: scale.label * 0.55) {
                    Spacer(minLength: 0)
                    dualRate(scale: scale, heroScale: 0.58)
                    microBars(Array(history.diskRead.suffix(Self.microStripCount)))
                        .frame(height: max(14, geo.size.height * 0.22))
                    Self.peakTag(label: String(localized: "R peak", comment: "Disk widget: recent read-rate peak label."),
                                 value: MonitorFormat.rate(history.diskReadPeak),
                                 size: scale.label)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    /// R hero row + W sub row — the shared "current pair" read (`dualRate`).
    private func dualRate(scale: MonitorDesign.TypeScale, heroScale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: scale.label * 0.3) {
            HStack(alignment: .firstTextBaseline, spacing: scale.hero * 0.06) {
                Text(verbatim: "R")
                    .font(.system(size: scale.hero * heroScale, weight: .bold, design: .rounded))
                    .foregroundStyle(Self.readColor)
                Self.rateHero(history.currentRead(sys), size: scale.hero * heroScale)
            }
            HStack(alignment: .firstTextBaseline, spacing: scale.sub * 0.09) {
                Text(verbatim: "W")
                    .font(.system(size: scale.sub, weight: .bold, design: .rounded))
                    .foregroundStyle(Self.writeColor)
                Text(verbatim: MonitorFormat.rate(sys.diskWriteBytesPerSec))
                    .font(MonitorDesign.subFont(size: scale.sub)).monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkMuted)
            }
        }
    }

    // MARK: - Medium (4×2)

    private var medium: some View {
        GeometryReader { geo in
            let scale = MonitorDesign.TypeScale(cellHeight: geo.size.height)
            MonitorWidgetContainer(label: "Disk", cellHeight: geo.size.height) {
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
                    footerRow(scale: scale)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
    }

    /// "R peak <rate>"  ↔  "Σ <total> · <age> ago".
    private func footerRow(scale: MonitorDesign.TypeScale) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Self.peakTag(label: String(localized: "R peak", comment: "Disk widget: recent read-rate peak label."),
                         value: MonitorFormat.rate(history.diskReadPeak),
                         size: scale.label)
            Spacer(minLength: 4)
            Text(verbatim: sessionSummary)
                .font(MonitorDesign.labelFont(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
                .lineLimit(1)
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
    // two options are a same-system backfill, keyed to match Memory's already-landed
    // convention (`historyWindow` seconds, `breakdown` full/compact) so a future
    // shared popover reads every widget the same way. Popover UI wiring is NOT part
    // of this file — see `MonitorWidgetSettingsPopover.swift` / the task report.

    /// `historyWindow` (seconds ≈ samples at the board's ~1Hz cadence) trims the
    /// M/L mirrored scope's trailing window. Absent/invalid ⇒ 120, matching the
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

    // MARK: - Large (4×4)
    //
    // A same-system backfill (see type doc) — not a 1:1 mock port. Reuses `medium`'s
    // current-pair row, then spends the extra height on real fields S/M already read
    // but have no room to show: the W peak (S/M show R only) and a session R/W split
    // rendered as a proportion bar (Memory's Activity-Monitor breakdown bar, sized
    // down to two segments). No top-process list — the schema carries no per-process
    // disk I/O attribution (`MonitorProcessSample` is cpu/mem only), so one isn't
    // fabricated here; see the task report's data-gap note.

    private var large: some View {
        GeometryReader { geo in
            // Half the tile height: L is a 2-row footprint, so this keeps the type
            // scale identical to S/M's single-row cards (L adds content, not bigger
            // type) — the same convention `MonitorCPUWidgetView` uses for its L.
            let cellHeight = geo.size.height / 2
            let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
            MonitorWidgetContainer(label: "Disk", cellHeight: cellHeight) {
                Text(verbatim: "ALL DISKS")
                    .foregroundStyle(MonitorDesign.inkFaint)
            } content: {
                VStack(alignment: .leading, spacing: scale.label * 0.6) {
                    currentPairRow(scale: scale)
                    historySectionLabel(scale: scale)
                    MirroredAreaChart(
                        up: Self.tail(history.diskRead, count: chartWindowSamples),
                        down: Self.tail(history.diskWrite, count: chartWindowSamples),
                        upColor: Self.readColor,
                        downColor: Self.writeColor
                    )
                    .frame(maxHeight: .infinity)
                    .frame(minHeight: scale.caption * 5)
                    sessionSectionLabel(scale: scale)
                    DiskSplitBar(
                        readFraction: sessionSplit.read,
                        writeFraction: sessionSplit.write,
                        readColor: Self.readColor,
                        writeColor: Self.writeColor
                    )
                    .frame(height: max(6, scale.caption * 1.05))
                    if !splitLegendCompact {
                        splitLegend(scale: scale)
                    }
                    peakAndFreshnessRow(scale: scale)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func historySectionLabel(scale: MonitorDesign.TypeScale) -> some View {
        (Text("History", comment: "Disk widget: L card's history-chart section label.")
            + Text(verbatim: " · \(chartWindowSamples)s"))
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

    /// Session Σ split into its R/W byte totals — a legend under the split bar.
    private func splitLegend(scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: scale.label * 1.4) {
            splitLegendItem(letter: "R", color: Self.readColor,
                             bytes: history.diskReadSessionBytes, scale: scale)
            splitLegendItem(letter: "W", color: Self.writeColor,
                             bytes: history.diskWriteSessionBytes, scale: scale)
            Spacer(minLength: 0)
        }
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

    /// Both R and W peaks (S/M show R only — L has the room for the pair) + freshness.
    private func peakAndFreshnessRow(scale: MonitorDesign.TypeScale) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.label * 1.1) {
            Self.peakTag(label: String(localized: "R peak", comment: "Disk widget: recent read-rate peak label."),
                         value: MonitorFormat.rate(history.diskReadPeak), size: scale.label)
            Self.peakTag(label: String(localized: "W peak", comment: "Disk widget: recent write-rate peak label."),
                         value: MonitorFormat.rate(history.diskWritePeak), size: scale.label)
            Spacer(minLength: 4)
            if let age = freshnessSeconds {
                Text(verbatim: MonitorFormat.ago(age) + " "
                     + String(localized: "ago", comment: "Relative-age suffix, e.g. '2m ago'."))
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
                    .lineLimit(1)
            }
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

    /// 30s micro-bar strip (`.mcols`): each bar's height is the sample normalised
    /// to the strip's own max, painted in the read hue.
    @ViewBuilder
    private func microBars(_ values: [Double]) -> some View {
        let mx = max(values.max() ?? 0, .ulpOfOne)
        GeometryReader { geo in
            let n = max(values.count, 1)
            let gap: CGFloat = 2
            let barW = max(1, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    let f = CGFloat(min(1, max(0, v / mx)))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Self.readColor.opacity(0.85))
                        .frame(width: barW, height: max(1, f * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
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

    /// Recent-peak tag: a small amber swatch + tracked label + tabular value.
    static func peakTag(label: String, value: String, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.35) {
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

#Preview("Disk · S (2×2)") {
    MonitorDiskWidgetView(context: diskMockContext(size: .small))
        .frame(width: 168, height: 168)
        .padding(28)
        .background(MonitorDesign.boardWash)
}

#Preview("Disk · M (4×2)") {
    MonitorDiskWidgetView(context: diskMockContext(size: .medium))
        .frame(width: 352, height: 168)
        .padding(28)
        .background(MonitorDesign.boardWash)
}

#Preview("Disk · L (4×4)") {
    MonitorDiskWidgetView(context: diskMockContext(size: .large))
        .frame(width: 352, height: 336)
        .padding(28)
        .background(MonitorDesign.boardWash)
}
#endif
