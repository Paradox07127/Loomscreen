import SwiftUI
import LiveWallpaperCore

struct MonitorProcessesWidgetView: View {
    let context: MonitorWidgetContext

    private var snapshot: MonitorSnapshot { context.snapshot }
    private var system: MonitorSystemSnapshot? { snapshot.system }

    private static let colProgram = "Program"
    private static let colCPU = "CPU"
    private static let colMEM = "MEM"

    var body: some View {
        GeometryReader { geo in
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

    /// Honest empty treatment: the top-process sampler only runs when enabled, so an absent/empty list means "not sampling", not "no processes".
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
        let maxCPU = max(rows.map(\.cpuPercent).max() ?? 0, .ulpOfOne)
        let base = scale.caption
        let cpuBarWidth = base * 2.6
        let cpuValueWidth = base * 2.2
        let cpuColWidth = cpuBarWidth + base * 0.45 + cpuValueWidth
        let memColWidth = base * 4.0
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

    /// Uses an SF Symbol when a metric header is too narrow for its acronym.
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

    /// `.pcpu` — the inline bar (fills to its share of the busiest row; the CPU widget's procRows track-plus-overlay idiom at its 2.6em width) + the cpu% readout (amber, tabular, fixed-width slot so digits align).
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

    /// The cpu% readout, no percent sign: one decimal under 10 (where tenths still carry signal), whole number from 10 up — the CPU widget's formatter convention.
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

    /// Calculates the number of whole process rows that fit the tile height.
    nonisolated static func rowCapacity(frameHeight: CGFloat, scaleHeight: CGFloat) -> Int {
        let scale = MonitorDesign.TypeScale(cellHeight: scaleHeight)
        let line: CGFloat = 1.25
        let shellChrome = MonitorDesign.contentInsetV * 2
            + scale.label * line + scale.label * 0.5
        let tableHeader = scale.label * line + scale.caption * 0.3 + MonitorDesign.hairlineWidth
        let rowPitch = scale.caption * line + scale.caption * 0.34
        let available = frameHeight - shellChrome - tableHeader
        guard rowPitch > 0, available > 0 else { return 0 }
        return Int((available / rowPitch).rounded(.down))
    }

    /// Whether a CPU/MEM header column is wide enough to set its 3-letter acronym at `labelSize` without truncating — the threshold the icon-fallback contingency switches on.
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
        reduceMotion: false,
        now: Date()
    )
}

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
