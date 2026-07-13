import SwiftUI
import LiveWallpaperCore

/// Processes widget — a native replica of the mock's `proc_m` row grammar
/// (`.claude/plan/monitor-design/index.html`). Top processes as rows, each a
/// three-column grid: program name (with a leading square glyph, truncating) ·
/// an inline CPU bar + integer cpu% · a right-aligned memory column. The eye
/// ranks by bar length, not by reading digits, so the bar is normalized to the
/// busiest row in the shown set (mock `proc_rows`: `clamp(c/max, 0, 1)`), never
/// to a fixed 100%.
///
/// `MonitorWidgetKind.allowedSizes` returns `[.medium, .large]` (S is cut — one
/// row is unreadable at 2×2). The mock itself never defines an L slot for this
/// card — only `m` (top 5) and a two-column `xl` (top 8 side-by-side) — so L
/// here is a deliberate native composite: same single-column grammar as M
/// (same width; the board only grows this card taller, never wider), with the
/// `xl` slot's column-density idea folded into row COUNT instead of a second
/// column. When the row-count `count` option (SPEC §7) is unset, M keeps the
/// mock's fixed 5; L auto-fills as many rows as its height holds, capped at
/// the settings stepper's ceiling of 8 (see `autoLargeRowLimit`). If handed
/// `.small` defensively, the same content renders compacted rather than
/// crashing.
///
/// Privacy: only the process display name is ever shown — never pid, path, or
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
            let cellHeight = geo.size.height
            let compact = context.placement.size == .small
            MonitorWidgetContainer(
                label: "Processes",
                systemImage: "list.bullet",
                cellHeight: cellHeight,
                status: { headerStatus(cellHeight: cellHeight) },
                content: { content(cellHeight: cellHeight, compact: compact) }
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerStatus(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let rows = displayedProcesses(cellHeight: cellHeight)
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
    private func content(cellHeight: CGFloat, compact: Bool) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let rows = displayedProcesses(cellHeight: cellHeight)
        if rows.isEmpty {
            quietState(scale: scale)
        } else {
            processTable(rows: rows, scale: scale, compact: compact)
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
        // .pic .5em · --cpucol 3.4em · MEM col 3.4em · grid gap .7em — all in
        // caption-em, matching `.proc .pr` in the mock CSS.
        let base = scale.caption
        let cpuColWidth = base * 3.4
        let memColWidth = base * 3.4
        let colGap = base * 0.7
        let rowGap = base * (compact ? 0.24 : 0.34)

        return VStack(alignment: .leading, spacing: rowGap) {
            headerRow(
                scale: scale, cpuColWidth: cpuColWidth,
                memColWidth: memColWidth, colGap: colGap
            )
            ForEach(Array(rows.enumerated()), id: \.offset) { _, proc in
                processRow(
                    proc, maxCPU: maxCPU, scale: scale,
                    cpuColWidth: cpuColWidth, memColWidth: memColWidth, colGap: colGap
                )
            }
            Spacer(minLength: 0)
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
    /// never truncates/overlaps). Dormant on this board today: `--cpucol`/MEM
    /// (3.4× the SAME caption base the label size clamps from) always clears
    /// `headerFitsText`'s threshold at both M and L, since only cellHeight —
    /// never column width — changes between them. Kept real (not decorative)
    /// so a future host with a genuinely narrow column still degrades cleanly.
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
    private func processRow(
        _ proc: MonitorProcessSample, maxCPU: Double,
        scale: MonitorDesign.TypeScale,
        cpuColWidth: CGFloat, memColWidth: CGFloat, colGap: CGFloat
    ) -> some View {
        HStack(spacing: colGap) {
            nameCell(proc.name, scale: scale)
                .frame(maxWidth: .infinity, alignment: .leading)
            cpuCell(proc.cpuPercent, maxCPU: maxCPU, scale: scale)
                .frame(width: cpuColWidth, alignment: .trailing)
            Text(verbatim: MonitorFormat.bytes(proc.memBytes))
                .font(MonitorDesign.captionFont(size: scale.caption * 0.94))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
                .frame(width: memColWidth, alignment: .trailing)
        }
        .font(MonitorDesign.captionFont(size: scale.caption))
    }

    /// `.pn` — leading square glyph + truncating name.
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

    /// `.pcpu` — the inline bar (fills to its share of the busiest row) + the
    /// integer cpu% readout (amber, tabular, fixed-width slot so digits align).
    private func cpuCell(
        _ cpuPercent: Double, maxCPU: Double, scale: MonitorDesign.TypeScale
    ) -> some View {
        let fraction = min(max(cpuPercent / maxCPU, 0), 1)
        return HStack(spacing: scale.caption * 0.45) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(MonitorDesign.track2)
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [MonitorDesign.oklch(0.6, 0.05, 78), MonitorDesign.signalAmber],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, g.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: scale.caption * 0.4)
            .frame(minWidth: scale.caption * 1.4)

            Text(verbatim: Self.cpuText(cpuPercent))
                .font(MonitorDesign.captionFont(size: scale.caption * 0.94))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.signalAmber)
                .frame(width: scale.caption * 2.1, alignment: .trailing)
        }
    }

    // MARK: - Derived data

    /// The rows to display: sampler-ordered top processes, re-sorted by cpu%
    /// descending defensively, capped to the resolved row limit.
    private func displayedProcesses(cellHeight: CGFloat) -> [MonitorProcessSample] {
        Self.topProcesses(system?.topProcesses, limit: rowLimit(cellHeight: cellHeight))
    }

    /// `count` widget option (SPEC §7 `Processes{count}`, `MonitorWidgetDraft`
    /// key/range) if the user set one — applies uniformly to whichever size is
    /// current, same as the settings popover's stepper. Absent that override:
    ///   • M keeps the mock's fixed default (`proc_m`'s "top 5").
    ///   • L (2× M's height, same width) auto-fills the available height —
    ///     the mock has no L slot to mirror, only a two-column `xl` capped at
    ///     8 — collapsed here into row count. See `autoLargeRowLimit`.
    private func rowLimit(cellHeight: CGFloat) -> Int {
        if let n = context.placement.options[MonitorWidgetDraft.countKey]?.numberValue {
            return min(
                max(Int(n), MonitorWidgetDraft.processCountRange.lowerBound),
                MonitorWidgetDraft.processCountRange.upperBound
            )
        }
        guard context.placement.size == .large else { return MonitorWidgetDraft.defaultProcessCount }
        return Self.autoLargeRowLimit(cellHeight: cellHeight)
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

    /// The cpu% readout: whole number, no percent sign (mock `c.toFixed(0)`).
    nonisolated static func cpuText(_ cpuPercent: Double) -> String {
        let v = cpuPercent.isFinite ? max(cpuPercent, 0) : 0
        return "\(Int(v.rounded()))"
    }

    /// Bar fill fraction 0…1: a row's cpu% over the busiest shown row.
    nonisolated static func barFraction(_ cpuPercent: Double, maxCPU: Double) -> Double {
        let denom = max(maxCPU, .ulpOfOne)
        return min(max(cpuPercent / denom, 0), 1)
    }

    /// L's height-driven default row count when `count` is unset: how many
    /// `.proc` rows fit under the widget-shell header + the in-card column
    /// header, floored at M's fixed default (never fewer rows than the
    /// smaller size shows) and capped at the settings stepper's ceiling
    /// (`MonitorWidgetDraft.processCountRange`, 8 — the mock's own `xl` row
    /// cap). The constants mirror `processTable`'s actual spacing exactly
    /// (contentInsetV, the shell header line, `.proc .ph`'s padding+hairline,
    /// `.proc` row gap `.34em`) so this never asks for more than fits on
    /// screen.
    nonisolated static func autoLargeRowLimit(cellHeight: CGFloat) -> Int {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let lineHeight: CGFloat = 1.2
        // MonitorWidgetContainer: content insets + its own header line + spacing.
        let shellChrome = MonitorDesign.contentInsetV * 2
            + scale.label * lineHeight + scale.label * 0.5
        // `.proc .ph` — the column-header row, its bottom padding, its hairline.
        let tableHeader = scale.label * lineHeight + scale.caption * 0.3 + MonitorDesign.hairlineWidth
        // `.proc .pr` row + `.proc`'s inter-row gap (.34em, non-compact).
        let rowHeight = scale.caption * lineHeight + scale.caption * 0.34
        let available = cellHeight - shellChrome - tableHeader
        guard rowHeight > 0, available > 0 else { return MonitorWidgetDraft.defaultProcessCount }
        let fitted = Int((available / rowHeight).rounded(.down))
        return min(
            max(fitted, MonitorWidgetDraft.defaultProcessCount),
            MonitorWidgetDraft.processCountRange.upperBound
        )
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
        // The mock's full DATA.processes (name · cpu · mem) — each size's own
        // capping (`rowLimit`) slices this down, exactly like `proc_m`/`proc_xl`
        // both slicing the same source array to their own row count.
        system.topProcesses = [
            MonitorProcessSample(name: "Xcode", cpuPercent: 52, memBytes: UInt64(3.4 * 1_073_741_824)),
            MonitorProcessSample(name: "kernel_task", cpuPercent: 31, memBytes: UInt64(1.2 * 1_073_741_824)),
            MonitorProcessSample(name: "Windows App (WPE)", cpuPercent: 23, memBytes: UInt64(1.1 * 1_073_741_824)),
            MonitorProcessSample(name: "claude (Helper)", cpuPercent: 23, memBytes: UInt64(1.4 * 1_073_741_824)),
            MonitorProcessSample(name: "WindowServer", cpuPercent: 18, memBytes: 640 * 1_048_576),
            MonitorProcessSample(name: "node", cpuPercent: 9, memBytes: 410 * 1_048_576),
            MonitorProcessSample(name: "LiveWallpaper", cpuPercent: 7, memBytes: UInt64(1.7 * 1_073_741_824)),
            MonitorProcessSample(name: "Safari", cpuPercent: 4, memBytes: 820 * 1_048_576)
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

// Frame sizes are the RAW cell footprint minus `tileInset` — the size this
// view's own GeometryReader actually receives at render time (SPEC runtime
// contract, 14" 1512×982pt board): M ≈378×196, L ≈378×392, less ~7pt/edge.
#Preview("Processes M") {
    MonitorProcessesWidgetView(context: processesMockContext(size: .medium))
        .frame(width: 364, height: 182)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Processes M (empty)") {
    MonitorProcessesWidgetView(context: processesMockContext(size: .medium, empty: true))
        .frame(width: 364, height: 182)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Processes L (auto row count)") {
    MonitorProcessesWidgetView(context: processesMockContext(size: .large))
        .frame(width: 364, height: 378)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Processes L (count override = 3)") {
    MonitorProcessesWidgetView(context: processesMockContext(size: .large, count: 3))
        .frame(width: 364, height: 378)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Processes L (empty)") {
    MonitorProcessesWidgetView(context: processesMockContext(size: .large, empty: true))
        .frame(width: 364, height: 378)
        .padding(32)
        .background(MonitorDesign.boardWash)
}
#endif
