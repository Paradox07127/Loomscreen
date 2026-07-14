import SwiftUI
import LiveWallpaperCore

/// Processes widget — a native replica of the mock's `proc_m` row grammar
/// (`.claude/plan/monitor-design/index.html`). Top apps as rows — the sampler
/// aggregates helper/XPC children under their top-level app (parent-PID walk)
/// and sorts by CPU — each a three-column grid: program name (with a leading
/// square glyph, truncating) · an inline CPU bar + cpu% readout (one decimal
/// under 10, whole number from 10 — the CPU widget's formatter) · a
/// right-aligned memory column. The numeric columns reserve fixed widths so
/// the rightmost value never clips; only names truncate. The eye ranks by bar
/// length, not by reading digits, so the bar is normalized to the busiest row
/// in the shown set (mock `proc_rows`: `clamp(c/max, 0, 1)`), never to a
/// fixed 100%.
///
/// Sizes are Apple's fixed macOS widget frames — M 364×170, L 364×376 visible —
/// on every display. `MonitorWidgetKind.allowedSizes` returns `[.medium,
/// .large]` (S is cut — one row is unreadable at 170×170). The mock never
/// defines an L slot for this card — only `m` (top 5) and a two-column wide
/// `xl` (top 8 side-by-side) — so L here is a deliberate native composite: the
/// same single-column grammar as M (same width; the board only grows this card
/// taller, never wider), with the `xl` slot's density idea folded into row
/// COUNT. When the row-count `count` option (SPEC §7) is unset, M keeps the
/// mock's fixed 5; L auto-fills to the settings stepper's ceiling of 12. Every
/// path is then clamped to `rowCapacity` — the rows that physically fit — so
/// the final row never clips at exactly 170/376 pt (L's capacity of 19 clears
/// the 12 ceiling; an M stepper override of 12 shows the 7 that fit). If
/// handed `.small` defensively, the same content renders compacted rather
/// than crashing.
///
/// Privacy: only the app display name is ever shown — never pid, path, or
/// bundle id. Pure function of `MonitorWidgetContext`.
struct MonitorProcessesWidgetView: View {
    let context: MonitorWidgetContext

    private var snapshot: MonitorSnapshot { context.snapshot }
    private var system: MonitorSystemSnapshot? { snapshot.system }

    // Header column labels — LISTed for i18n.
    private static let colProgram = "Program"
    private static let colCPU = "CPU"
    private static let colMEM = "MEM"

    var body: some View {
        GeometryReader { geo in
            // The mock derives type from the PER-ROW cell height (`d.h / d.rows`):
            // M spans one board row and L two, so dividing by 2·rowSpan yields a
            // near-constant type reference (85/94 pt at the fixed frames) — L
            // holds more rows, not bigger text. Row capacity, by contrast, needs
            // the FULL frame height; the two are passed separately below.
            let rowSpan: CGFloat = context.placement.size == .large ? 2 : 1
            let scaleHeight = geo.size.height / (2 * rowSpan)
            let scale = MonitorDesign.TypeScale(cellHeight: scaleHeight)
            let rows = displayedProcesses(
                frameHeight: geo.size.height, scaleHeight: scaleHeight
            )
            MonitorWidgetContainer(
                label: "Processes",
                systemImage: "list.bullet",
                cellHeight: scaleHeight,
                status: { headerStatus(rows: rows, scale: scale) },
                content: { content(rows: rows, scale: scale) }
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerStatus(
        rows: [MonitorProcessSample], scale: MonitorDesign.TypeScale
    ) -> some View {
        if !rows.isEmpty {
            // "top 5" — the emphasis word is the count, whispered around it.
            HStack(spacing: 3) {
                Text("top")
                    .foregroundStyle(MonitorDesign.inkFaint)
                Text(verbatim: "\(rows.count)")
                    .foregroundStyle(MonitorDesign.inkMuted)
            }
            .font(MonitorDesign.subFont(size: scale.label))
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func content(
        rows: [MonitorProcessSample], scale: MonitorDesign.TypeScale
    ) -> some View {
        if rows.isEmpty {
            quietState(scale: scale)
        } else {
            processTable(
                rows: rows, scale: scale,
                compact: context.placement.size == .small
            )
        }
    }

    /// Honest empty treatment: the top-process sampler only runs when enabled, so
    /// an absent/empty list means "not sampling", not "no processes". A single
    /// whisper line, never fabricated rows.
    private func quietState(scale: MonitorDesign.TypeScale) -> some View {
        VStack(alignment: .leading) {
            Spacer(minLength: 0)
            Text("no process readings")
                .font(MonitorDesign.captionFont(size: scale.caption))
                .foregroundStyle(MonitorDesign.inkFaint)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func processTable(
        rows: [MonitorProcessSample], scale: MonitorDesign.TypeScale, compact: Bool
    ) -> some View {
        // Bars normalize to the busiest shown row (mock `proc_rows`); guard 0.
        let maxCPU = max(rows.map(\.cpuPercent).max() ?? 0, .ulpOfOne)
        // Numeric columns reserve fixed caption-em widths sized to their widest
        // realistic value, so the rightmost cell never clips and only names
        // truncate: CPU = 2.6em bar (the CPU widget's procRows width) + gap +
        // 2.2em readout ("9.4"/"100"-wide); MEM = 4em ("1023 MB"-wide).
        let base = scale.caption
        let cpuBarWidth = base * 2.6
        let cpuValueWidth = base * 2.2
        let cpuColWidth = cpuBarWidth + base * 0.45 + cpuValueWidth
        let memColWidth = base * 4.0
        let colGap = base * 0.7
        let rowGap = base * (compact ? 0.24 : 0.34)

        // Top-aligned, no trailing spacer: the outer frame already pins the
        // table up, and `rowCapacity` budgets exactly header + N×(row+gap).
        return VStack(alignment: .leading, spacing: rowGap) {
            headerRow(
                scale: scale, cpuColWidth: cpuColWidth,
                memColWidth: memColWidth, colGap: colGap
            )
            ForEach(Array(rows.enumerated()), id: \.offset) { _, proc in
                processRow(
                    proc, maxCPU: maxCPU, scale: scale,
                    cpuBarWidth: cpuBarWidth, cpuValueWidth: cpuValueWidth,
                    memColWidth: memColWidth, colGap: colGap
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// `.ph` — column labels, uppercase/tracked, with a hairline underline.
    private func headerRow(
        scale: MonitorDesign.TypeScale,
        cpuColWidth: CGFloat, memColWidth: CGFloat, colGap: CGFloat
    ) -> some View {
        HStack(spacing: colGap) {
            // "Program" is a word (localized); "CPU"/"MEM" are acronyms (verbatim).
            localizedColumnLabel(Self.colProgram, scale: scale)
                .frame(maxWidth: .infinity, alignment: .leading)
            columnHeader(Self.colCPU, systemImage: "cpu", columnWidth: cpuColWidth, scale: scale)
                .frame(width: cpuColWidth, alignment: .center)
            columnHeader(Self.colMEM, systemImage: "memorychip", columnWidth: memColWidth, scale: scale)
                .frame(width: memColWidth, alignment: .trailing)
        }
        .padding(.bottom, scale.caption * 0.3)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MonitorDesign.hairline.opacity(0.5))
                .frame(height: MonitorDesign.hairlineWidth)
        }
    }

    /// A CPU/MEM header cell: the acronym, or — Apple-widget-style contingency
    /// for a column too narrow to set it — an SF Symbol standing in for the
    /// word instead of shrinking or clipping it (runtime contract: header text
    /// never truncates/overlaps). Dormant at the fixed M/L frames: both
    /// columns (≥4× the SAME caption base the label size clamps from) always
    /// clear `headerFitsText`'s threshold, since only cellHeight — never
    /// column width — changes between them. Kept real (not decorative) so a
    /// future host with a genuinely narrow column still degrades cleanly.
    @ViewBuilder
    private func columnHeader(
        _ text: String, systemImage: String, columnWidth: CGFloat, scale: MonitorDesign.TypeScale
    ) -> some View {
        if Self.headerFitsText(columnWidth: columnWidth, labelSize: scale.label) {
            columnLabel(text, scale: scale)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: scale.label, weight: .semibold))
                .foregroundStyle(MonitorDesign.inkFaint)
                .accessibilityLabel(Text(verbatim: text))
        }
    }

    private func columnLabel(_ text: String, scale: MonitorDesign.TypeScale) -> some View {
        Text(verbatim: text.uppercased())
            .font(MonitorDesign.labelFont(size: scale.label))
            .tracking(scale.label * 0.10)
            .foregroundStyle(MonitorDesign.inkFaint)
    }

    /// A column label whose text is a localizable word (the catalog key is the
    /// English constant); uppercased for display (a no-op for non-Latin scripts).
    private func localizedColumnLabel(_ key: String, scale: MonitorDesign.TypeScale) -> some View {
        Text(LocalizedStringKey(key))
            .font(MonitorDesign.labelFont(size: scale.label))
            .tracking(scale.label * 0.10)
            .foregroundStyle(MonitorDesign.inkFaint)
            .textCase(.uppercase)
            .lineLimit(1)
    }

    /// `.pr` — one process: name cell (1fr) · CPU cell (bar + value) · MEM cell.
    /// Rows are strictly single-line; the numeric cells sit in widths reserved
    /// for their widest realistic value, with compression (min scale .7) only
    /// as an outlier backstop (a 4-digit cpu%, a "102.4 GB" footprint).
    private func processRow(
        _ proc: MonitorProcessSample, maxCPU: Double,
        scale: MonitorDesign.TypeScale,
        cpuBarWidth: CGFloat, cpuValueWidth: CGFloat,
        memColWidth: CGFloat, colGap: CGFloat
    ) -> some View {
        HStack(spacing: colGap) {
            nameCell(proc.name, scale: scale)
                .frame(maxWidth: .infinity, alignment: .leading)
            cpuCell(
                proc.cpuPercent, maxCPU: maxCPU, scale: scale,
                barWidth: cpuBarWidth, valueWidth: cpuValueWidth
            )
            Text(verbatim: MonitorFormat.bytes(proc.memBytes))
                .font(MonitorDesign.captionFont(size: scale.caption * 0.94))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
                .minimumScaleFactor(0.7)
                .frame(width: memColWidth, alignment: .trailing)
        }
        .font(MonitorDesign.captionFont(size: scale.caption))
        .lineLimit(1)
    }

    /// `.pn` — leading square glyph + truncating name (names truncate rather
    /// than shrink, so the name column stays optically even down the table).
    private func nameCell(_ name: String, scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: scale.caption * 0.5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(MonitorDesign.inkFaint.opacity(0.7))
                .frame(width: scale.caption * 0.5, height: scale.caption * 0.5)
            Text(verbatim: name)
                .font(MonitorDesign.captionFont(size: scale.caption))
                .foregroundStyle(MonitorDesign.inkPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// `.pcpu` — the inline bar (fills to its share of the busiest row; the CPU
    /// widget's procRows track-plus-overlay idiom at its 2.6em width) + the
    /// cpu% readout (amber, tabular, fixed-width slot so digits align).
    private func cpuCell(
        _ cpuPercent: Double, maxCPU: Double, scale: MonitorDesign.TypeScale,
        barWidth: CGFloat, valueWidth: CGFloat
    ) -> some View {
        let fraction = Self.barFraction(cpuPercent, maxCPU: maxCPU)
        return HStack(spacing: scale.caption * 0.45) {
            Capsule(style: .continuous)
                .fill(MonitorDesign.track2)
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [MonitorDesign.oklch(0.6, 0.05, 78), MonitorDesign.signalAmber],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, barWidth * CGFloat(fraction)))
                }
                .frame(width: barWidth, height: max(scale.caption * 0.42, 4))

            Text(verbatim: Self.cpuText(cpuPercent))
                .font(MonitorDesign.captionFont(size: scale.caption * 0.94))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.signalAmber)
                .minimumScaleFactor(0.7)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    // MARK: - Derived data

    /// The rows to display: sampler-ordered top apps, re-sorted by cpu%
    /// descending defensively, capped to the resolved row limit.
    private func displayedProcesses(
        frameHeight: CGFloat, scaleHeight: CGFloat
    ) -> [MonitorProcessSample] {
        Self.topProcesses(
            system?.topProcesses,
            limit: rowLimit(frameHeight: frameHeight, scaleHeight: scaleHeight)
        )
    }

    /// Requested rows: the `count` widget option (SPEC §7 `Processes{count}`,
    /// `MonitorWidgetDraft` key/range) if the user set one — applied uniformly
    /// to whichever size is current, same as the settings popover's stepper.
    /// Absent that override, M keeps the mock's fixed default (`proc_m`'s
    /// "top 5") and L auto-fills to the stepper ceiling of 12 (also the
    /// sampler's list depth; L's physical capacity of 19 clears it). EVERY
    /// path is then clamped to `rowCapacity` — never draw a row the fixed
    /// frame can't finish (at M's 170 pt a stepper 12 shows the 7 that fit;
    /// the header count stays honest because it reads the displayed list's
    /// length).
    private func rowLimit(frameHeight: CGFloat, scaleHeight: CGFloat) -> Int {
        let capacity = max(
            Self.rowCapacity(frameHeight: frameHeight, scaleHeight: scaleHeight), 1
        )
        let requested: Int
        if let n = context.placement.options[MonitorWidgetDraft.countKey]?.numberValue {
            requested = min(
                max(Int(n), MonitorWidgetDraft.processCountRange.lowerBound),
                MonitorWidgetDraft.processCountRange.upperBound
            )
        } else if context.placement.size == .large {
            requested = MonitorWidgetDraft.processCountRange.upperBound
        } else {
            requested = MonitorWidgetDraft.defaultProcessCount
        }
        return min(requested, capacity)
    }

    // MARK: - Pure helpers (nonisolated for tests)

    /// Sampler-ordered list re-sorted by cpu% descending (stable on ties by the
    /// original order) and capped to `limit`. `nil`/empty in → empty out.
    nonisolated static func topProcesses(
        _ processes: [MonitorProcessSample]?, limit: Int
    ) -> [MonitorProcessSample] {
        guard let processes, !processes.isEmpty else { return [] }
        let sorted = processes.enumerated().sorted { lhs, rhs in
            if lhs.element.cpuPercent != rhs.element.cpuPercent {
                return lhs.element.cpuPercent > rhs.element.cpuPercent
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return Array(sorted.prefix(max(0, limit)))
    }

    /// The cpu% readout, no percent sign: one decimal under 10 (where tenths
    /// still carry signal), whole number from 10 up — the CPU widget's
    /// formatter convention. Rounds to tenths FIRST so 9.97 lands as "10",
    /// never "10.0".
    nonisolated static func cpuText(_ cpuPercent: Double) -> String {
        let v = cpuPercent.isFinite ? max(cpuPercent, 0) : 0
        let tenths = (v * 10).rounded() / 10
        if tenths < 10 { return String(format: "%.1f", tenths) }
        return "\(Int(v.rounded()))"
    }

    /// Bar fill fraction 0…1: a row's cpu% over the busiest shown row.
    nonisolated static func barFraction(_ cpuPercent: Double, maxCPU: Double) -> Double {
        let denom = max(maxCPU, .ulpOfOne)
        return min(max(cpuPercent / denom, 0), 1)
    }

    /// Whole `.pr` rows that physically fit in a tile `frameHeight` pt tall:
    /// subtract the widget-shell chrome (content insets + header line +
    /// spacing) and the in-card column header, then divide by the row pitch
    /// (one row + the VStack gap that precedes every row). The constants
    /// mirror `processTable`'s actual layout — `.proc .ph`'s padding +
    /// hairline, `.proc`'s .34em row gap — and the 1.25 line factor slightly
    /// over-budgets SF's real ~1.19–1.23× line heights, so a row this counts
    /// as fitting can never clip. At the fixed Apple frames: M 170 pt
    /// (scale 85) → 7; L 376 pt (scale 94) → 19, where the stepper/sampler
    /// cap of 8 binds first. 0 when chrome alone overflows the frame.
    nonisolated static func rowCapacity(frameHeight: CGFloat, scaleHeight: CGFloat) -> Int {
        let scale = MonitorDesign.TypeScale(cellHeight: scaleHeight)
        let line: CGFloat = 1.25
        // MonitorWidgetContainer: content insets + its own header line + spacing.
        let shellChrome = MonitorDesign.contentInsetV * 2
            + scale.label * line + scale.label * 0.5
        // `.proc .ph` — the column-header row, its bottom padding, its hairline.
        let tableHeader = scale.label * line + scale.caption * 0.3 + MonitorDesign.hairlineWidth
        // `.proc .pr` row + `.proc`'s inter-row gap (.34em, non-compact).
        let rowPitch = scale.caption * line + scale.caption * 0.34
        let available = frameHeight - shellChrome - tableHeader
        guard rowPitch > 0, available > 0 else { return 0 }
        return Int((available / rowPitch).rounded(.down))
    }

    /// Whether a CPU/MEM header column is wide enough to set its 3-letter
    /// acronym at `labelSize` without truncating — the threshold the
    /// icon-fallback contingency switches on. Modeled as ~0.62em average
    /// glyph advance (SF Rounded semibold, uppercase) × 3 characters, plus the
    /// label's own tracking (`MonitorDesign.labelTracking`) on both sides.
    nonisolated static func headerFitsText(columnWidth: CGFloat, labelSize: CGFloat) -> Bool {
        let glyphWidth = labelSize * 0.62 * 3
        let tracking = MonitorDesign.labelTracking(size: labelSize) * 2
        return columnWidth >= glyphWidth + tracking
    }
}

// MARK: - Previews

#if DEBUG
private func processesMockContext(
    size: MonitorWidgetSize, empty: Bool = false, count: Int? = nil
) -> MonitorWidgetContext {
    var system = MonitorSystemSnapshot()
    if !empty {
        // The mock's DATA.processes (name · cpu · mem), extended to the
        // sampler's 12-row depth so the L preview exercises its full auto-fill
        // ceiling; sub-10% rows carry tenths to show the decimal readout.
        // Each size's own capping (`rowLimit`) slices this down, exactly like
        // `proc_m`/`proc_xl` both slicing the same source array.
        system.topProcesses = [
            MonitorProcessSample(name: "Xcode", cpuPercent: 52, memBytes: UInt64(3.4 * 1_073_741_824)),
            MonitorProcessSample(name: "kernel_task", cpuPercent: 31, memBytes: UInt64(1.2 * 1_073_741_824)),
            MonitorProcessSample(name: "Windows App (WPE)", cpuPercent: 23, memBytes: UInt64(1.1 * 1_073_741_824)),
            MonitorProcessSample(name: "claude (Helper)", cpuPercent: 23, memBytes: UInt64(1.4 * 1_073_741_824)),
            MonitorProcessSample(name: "WindowServer", cpuPercent: 18, memBytes: 640 * 1_048_576),
            MonitorProcessSample(name: "node", cpuPercent: 9.4, memBytes: 410 * 1_048_576),
            MonitorProcessSample(name: "LiveWallpaper", cpuPercent: 7.2, memBytes: UInt64(1.7 * 1_073_741_824)),
            MonitorProcessSample(name: "Safari", cpuPercent: 4.1, memBytes: 820 * 1_048_576),
            MonitorProcessSample(name: "Finder", cpuPercent: 2.3, memBytes: 310 * 1_048_576),
            MonitorProcessSample(name: "mds_stores", cpuPercent: 1.8, memBytes: 1023 * 1_048_576),
            MonitorProcessSample(name: "coreaudiod", cpuPercent: 0.9, memBytes: 96 * 1_048_576),
            MonitorProcessSample(name: "Terminal", cpuPercent: 0.4, memBytes: 210 * 1_048_576)
        ]
    }
    var options: [String: MonitorWidgetOptionValue] = [:]
    if let count { options[MonitorWidgetDraft.countKey] = .number(Double(count)) }
    return MonitorWidgetContext(
        snapshot: MonitorSnapshot(timestamp: 0, system: system),
        history: MonitorHistorySnapshot(),
        placement: MonitorWidgetPlacement(kind: .processes, size: size, options: options),
        isEditing: false,
        isAgentFleetEnabled: false,
        reduceMotion: false,
        now: Date()
    )
}

// Frames are Apple's exact visible widget tiles (HIG Widgets → Specifications),
// the size the board's render inset hands this view on EVERY display:
// M 364×170, L 364×376.
#Preview("Processes M") {
    MonitorProcessesWidgetView(context: processesMockContext(size: .medium))
        .frame(width: 364, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Processes M (count 12 → capacity clamps to 7)") {
    MonitorProcessesWidgetView(context: processesMockContext(size: .medium, count: 12))
        .frame(width: 364, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Processes M (empty)") {
    MonitorProcessesWidgetView(context: processesMockContext(size: .medium, empty: true))
        .frame(width: 364, height: 170)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Processes L (auto row count → 12-row ceiling)") {
    MonitorProcessesWidgetView(context: processesMockContext(size: .large))
        .frame(width: 364, height: 376)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Processes L (count override = 3)") {
    MonitorProcessesWidgetView(context: processesMockContext(size: .large, count: 3))
        .frame(width: 364, height: 376)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Processes L (empty)") {
    MonitorProcessesWidgetView(context: processesMockContext(size: .large, empty: true))
        .frame(width: 364, height: 376)
        .padding(32)
        .background(MonitorDesign.boardWash)
}
#endif
