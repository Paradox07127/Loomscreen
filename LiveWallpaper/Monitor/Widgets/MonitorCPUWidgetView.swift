import SwiftUI
import LiveWallpaperCore

struct MonitorCPUWidgetView: View {
    let context: MonitorWidgetContext

    private var system: MonitorSystemSnapshot? { context.snapshot.system }
    private var history: MonitorHistorySnapshot { context.history }
    private var placement: MonitorWidgetPlacement { context.placement }

    var body: some View {
        GeometryReader { geo in
            let rowSpan: CGFloat = placement.size == .large ? 2 : 1
            let cellHeight = geo.size.height / (2 * rowSpan)
            content(cellHeight: cellHeight)
        }
    }

    @ViewBuilder
    private func content(cellHeight: CGFloat) -> some View {
        switch placement.size {
        case .small: smallBody(cellHeight: cellHeight)
        case .medium: mediumBody(cellHeight: cellHeight)
        case .large: largeBody(cellHeight: cellHeight)
        }
    }

    // MARK: - Derived values

    private var cpuFraction: Double { system?.cpuTotal ?? 0 }
    private var peakFraction: Double { history.cpuPeak }

    /// Trailing window (seconds ≈ 1 Hz samples) of the total-load history.
    private func trend(_ seconds: Int) -> [Double] {
        Array(history.cpuTotal.suffix(max(seconds, 2)))
    }

    private var cpuTempC: Double? { system?.sensors?.cpuTempC ?? system?.sensors?.socTempC }
    private var cpuPowerW: Double? { system?.sensors?.cpuPowerW }

    private var showSensors: Bool { MonitorCPUDraft.showSensors(placement) }
    private var showHeatmap: Bool { MonitorCPUDraft.showHeatmap(placement) }
    private var showComposition: Bool { MonitorCPUDraft.showComposition(placement) }
    private var showTrend: Bool { MonitorCPUDraft.showTrend(placement) }
    private var historyWindow: Int { MonitorCPUDraft.historyWindow(placement) }

    /// Sensor UI is only ever drawn when the reading exists AND the option is on.
    private var sensorsVisible: Bool { showSensors && (cpuTempC != nil || cpuPowerW != nil) }
    private var tempCapsuleTemp: Double? { showSensors ? cpuTempC : nil }

    // MARK: - S (1×1)

    @ViewBuilder
    private func smallBody(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        MonitorWidgetContainer(
            label: "CPU",
            systemImage: "cpu",
            cellHeight: cellHeight,
            status: { CPUStateDot(fraction: cpuFraction) }
        ) {
            VStack(spacing: scale.label * 0.55) {
                Spacer(minLength: 0)
                let hasTemp = tempCapsuleTemp != nil
                let heroSize = scale.hero * (hasTemp ? 0.9 : 1)
                ArcGauge(value: cpuFraction, peak: peakFraction) {
                    heroReadout(fraction: cpuFraction, heroSize: heroSize, unitSize: heroSize * 0.4)
                }
                .frame(maxWidth: hasTemp ? 126 : 138)

                if let temp = tempCapsuleTemp {
                    temperatureCapsule(temp, scale: scale)
                }

                Spacer(minLength: 0)

                if showTrend {
                    Sparkline(values: trend(historyWindow), domain: 0...1, bandColored: true, guides: [0.4, 0.8])
                        .frame(maxWidth: .infinity)
                        .frame(height: max(cellHeight * 0.24, 20))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - M (2×1)

    @ViewBuilder
    private func mediumBody(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let user = system?.cpuUser ?? 0
        let sys = system?.cpuSystem ?? 0
        let (userPct, sysPct, _) = Self.compositionPercents(user: user, system: sys)
        MonitorWidgetContainer(
            label: "CPU",
            systemImage: "cpu",
            cellHeight: cellHeight,
            status: { CPUStateDot(fraction: cpuFraction) }
        ) {
            VStack(alignment: .leading, spacing: scale.label * 0.5) {
                if let identity = Self.identityLine(system?.cpuInfo) {
                    identityRow(identity, scale: scale)
                }

                HStack(alignment: .center, spacing: scale.label * 0.7) {
                    VStack(alignment: .leading, spacing: scale.label * 0.45) {
                        ArcGauge(
                            value: cpuFraction,
                            bands: showComposition
                                ? [ArcBand(user, MonitorDesign.signalAmber), ArcBand(sys, MonitorDesign.signalSteel)]
                                : nil
                        ) {
                            heroReadout(fraction: cpuFraction,
                                        heroSize: scale.hero * 1.05, unitSize: scale.hero * 1.05 * 0.4)
                        }
                        .frame(maxWidth: 96)
                        if showComposition {
                            compositionLegend(userPct: userPct, sysPct: sysPct, scale: scale)
                        }
                    }
                    .frame(maxWidth: 104, alignment: .leading)

                    VStack(alignment: .leading, spacing: scale.label * 0.5) {
                        if showHeatmap { coreHeatStrip(scale: scale) }
                        Sparkline(values: trend(historyWindow), domain: 0...1, bandColored: true, guides: [0.4, 0.8])
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(minHeight: max(cellHeight * 0.18, 20))
                            .overlay(alignment: .topTrailing) { peakInlineTag(scale: scale) }
                        if sensorsVisible { sensorRow(scale: scale) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - L (2×2)

    @ViewBuilder
    private func largeBody(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        MonitorWidgetContainer(
            label: "CPU",
            systemImage: "cpu",
            cellHeight: cellHeight,
            status: { CPUStateDot(fraction: cpuFraction) }
        ) {
            VStack(alignment: .leading, spacing: scale.label * 0.6) {
                if let identity = Self.identityLine(system?.cpuInfo) {
                    identityRow(identity, scale: scale)
                }

                // Keep the header aligned to the standard content inset.
                HStack(alignment: .center, spacing: scale.label * 0.7) {
                    ArcGauge(value: cpuFraction, peak: peakFraction) {
                        heroReadout(fraction: cpuFraction,
                                    heroSize: scale.hero * 0.92, unitSize: scale.hero * 0.92 * 0.4)
                    }
                    .frame(width: 96)

                    VStack(alignment: .leading, spacing: scale.label * 0.45) {
                        if showComposition {
                            compositionBar(scale: scale, centeredLegend: false, legendScale: 1)
                        }
                        HStack(spacing: scale.label * 0.5) {
                            thermalPill(scale: scale)
                            loadStatus(scale: scale, triple: true)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)

                CPUStackChart(
                    user: Array(history.cpuUser.suffix(historyWindow)),
                    system: Array(history.cpuSystem.suffix(historyWindow))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: max(cellHeight * 0.32, 32))
                .overlay(alignment: .topTrailing) { peakInlineTag(scale: scale) }

                let groups = showHeatmap
                    ? Self.coreGroupLoads(perCore: system?.perCore, cpuInfo: system?.cpuInfo)
                    : nil
                let procs = Self.topCPUProcesses(system?.topProcesses, limit: 4)
                if groups != nil || procs?.isEmpty == false {
                    HStack(alignment: .top, spacing: scale.label * 0.9) {
                        if let groups {
                            VStack(alignment: .leading, spacing: scale.label * 0.4) {
                                sectionLabel("Cores · \(Self.coreCountText(groups))", scale: scale)
                                coreHeatStripTall(groups: groups, scale: scale)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        if let procs, !procs.isEmpty {
                            VStack(alignment: .leading, spacing: scale.label * 0.4) {
                                sectionLabel("Top by CPU", scale: scale)
                                procRows(procs, scale: scale)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }

                if sensorsVisible { sensorStrip(scale: scale) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Shared subviews

    @ViewBuilder
    private func heroReadout(fraction: Double, heroSize: CGFloat, unitSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: Self.wholeNumber(fraction))
                .font(MonitorDesign.heroFont(size: heroSize))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
            Text(verbatim: "%")
                .font(MonitorDesign.heroFont(size: unitSize))
                .foregroundStyle(MonitorDesign.inkFaint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    /// Whisper section header (L's "Cores · N" / "Top by CPU" column titles).
    @ViewBuilder
    private func sectionLabel(_ text: String, scale: MonitorDesign.TypeScale) -> some View {
        Text(verbatim: text)
            .font(MonitorDesign.labelFont(size: scale.label))
            .tracking(MonitorDesign.labelTracking(size: scale.label))
            .foregroundStyle(MonitorDesign.inkFaint)
            .lineLimit(1)
    }

    /// B-tier temperature capsule (S) — own cool→warm ramp + a "cool/warm/hot" word.
    @ViewBuilder
    private func temperatureCapsule(_ celsius: Double, scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.5) {
            Circle()
                .fill(MonitorDesign.temperatureColor(celsius))
                .frame(width: scale.caption * 0.62, height: scale.caption * 0.62)
                .shadow(color: MonitorDesign.temperatureColor(celsius).opacity(0.7), radius: 2)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(verbatim: Self.tempValue(celsius))
                    .font(MonitorDesign.subFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkPrimary)
                Text(verbatim: MonitorTemperature.symbol)
                    .font(MonitorDesign.captionFont(size: scale.caption * 0.68))
                    .foregroundStyle(MonitorDesign.inkFaint)
            }
            Text(LocalizedStringKey(Self.temperatureWord(celsius)))
                .font(MonitorDesign.labelFont(size: scale.label * 0.94))
                .tracking(scale.label * 0.12)
                .foregroundStyle(MonitorDesign.inkFaint)
        }
        .padding(.vertical, scale.label * 0.3)
        .padding(.leading, scale.label * 0.55)
        .padding(.trailing, scale.label * 0.7)
        .background(
            Capsule(style: .continuous)
                .fill(MonitorDesign.bg2.opacity(0.5))
                .overlay(Capsule(style: .continuous).strokeBorder(MonitorDesign.hairlineHi.opacity(0.55), lineWidth: 1))
        )
    }

    @ViewBuilder
    private func compositionBar(scale: MonitorDesign.TypeScale, centeredLegend: Bool, legendScale: CGFloat) -> some View {
        let user = system?.cpuUser ?? 0
        let sys = system?.cpuSystem ?? 0
        let (userPct, sysPct, idlePct) = Self.compositionPercents(user: user, system: sys)
        VStack(alignment: centeredLegend ? .center : .leading, spacing: scale.label * 0.4) {
            GeometryReader { g in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(LinearGradient(colors: [MonitorDesign.oklch(0.6, 0.05, 78), MonitorDesign.signalAmber],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * CGFloat(min(max(user, 0), 1)))
                    Rectangle()
                        .fill(LinearGradient(colors: [MonitorDesign.oklch(0.5, 0.03, 235), MonitorDesign.signalSteel],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * CGFloat(min(max(sys, 0), 1)))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: max(scale.caption * 0.72, 6))
            .background(MonitorDesign.track)
            .clipShape(Capsule(style: .continuous))

            HStack(spacing: scale.label * 0.9) {
                compLegendItem("USER", value: userPct, dot: MonitorDesign.signalAmber, scale: scale, sizeScale: legendScale)
                compLegendItem("SYS", value: sysPct, dot: MonitorDesign.signalSteel, scale: scale, sizeScale: legendScale)
                compLegendItem("IDLE", value: idlePct, dot: MonitorDesign.oklch(0.4, 0.01, 74), scale: scale, sizeScale: legendScale)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: centeredLegend ? .center : .leading)
        }
    }

    @ViewBuilder
    private func compLegendItem(_ label: String, value: Int, dot: Color,
                                scale: MonitorDesign.TypeScale, sizeScale: CGFloat) -> some View {
        let size = scale.label * sizeScale
        HStack(spacing: size * 0.4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(dot)
                .frame(width: size * 0.6, height: size * 0.6)
            Text(verbatim: "\(label) \(value)%")
                .font(MonitorDesign.labelFont(size: size))
                .foregroundStyle(MonitorDesign.inkFaint)
        }
    }

    /// Compact user/sys legend under the M arc (the arc's own two-tone wedges are the primary encoding; this just labels the split with percentages).
    @ViewBuilder
    private func compositionLegend(userPct: Int, sysPct: Int, scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.8) {
            legendValue("USER", value: userPct, color: MonitorDesign.signalAmber, scale: scale)
            legendValue("SYS", value: sysPct, color: MonitorDesign.signalSteel, scale: scale)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .monitorChip(scale)
    }

    @ViewBuilder
    private func legendValue(_ label: String, value: Int, color: Color, scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.35) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: scale.label * 0.6, height: scale.label * 0.6)
            Text(verbatim: "\(label) \(value)%")
                .font(MonitorDesign.labelFont(size: scale.label * 0.95))
                .foregroundStyle(MonitorDesign.inkFaint)
                .monospacedDigit()
        }
    }

    /// "PEAK n%" tag pinned inside the top-right of the M load curve (was a separate row under the arc).
    @ViewBuilder
    private func peakInlineTag(scale: MonitorDesign.TypeScale) -> some View {
        let size = scale.label * 0.9
        HStack(alignment: .firstTextBaseline, spacing: size * 0.3) {
            Text(verbatim: "PEAK")
                .font(MonitorDesign.labelFont(size: size))
                .tracking(size * 0.1)
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: Self.wholePercent(peakFraction))
                .font(MonitorDesign.subFont(size: size))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
        }
        .monitorChip(scale)
        .padding(size * 0.3)
    }

    /// Per-core heat strip (M, compact): clusters side by side.
    @ViewBuilder
    private func coreHeatStrip(scale: MonitorDesign.TypeScale) -> some View {
        if let groups = Self.coreGroupLoads(perCore: system?.perCore, cpuInfo: system?.cpuInfo), !groups.isEmpty {
            let bandHeight = max(scale.caption * 1.25, 13)
            HStack(alignment: .top, spacing: scale.label * 0.9) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    let rows = group.loads.count > 8 ? 2 : 1
                    VStack(alignment: .leading, spacing: scale.label * 0.3) {
                        clusterLabel(group, scale: scale)
                        heatCellGrid(group.loads, rows: rows, bandHeight: bandHeight)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Lay a cluster's cells into `rows` equal rows that together fill `bandHeight` (so a 1-row and a 2-row cluster stand the same height).
    @ViewBuilder
    private func heatCellGrid(_ loads: [Double], rows: Int, bandHeight: CGFloat) -> some View {
        let gap: CGFloat = 2
        let rowCount = max(rows, 1)
        let perRow = Int(ceil(Double(loads.count) / Double(rowCount)))
        let cellHeight = rowCount > 1 ? (bandHeight - gap * CGFloat(rowCount - 1)) / CGFloat(rowCount) : bandHeight
        VStack(spacing: gap) {
            ForEach(0..<rowCount, id: \.self) { row in
                let slice = Array(loads.dropFirst(row * perRow).prefix(perRow))
                HStack(spacing: gap) {
                    ForEach(Array(slice.enumerated()), id: \.offset) { _, load in
                        HeatCell(load: load, height: cellHeight)
                    }
                    if slice.count < perRow {
                        ForEach(0..<(perRow - slice.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: cellHeight)
                        }
                    }
                }
            }
        }
    }

    /// Per-core heat strip (L, tall): clusters stacked, each a full-width bar row.
    @ViewBuilder
    private func coreHeatStripTall(groups: [CoreGroupLoads], scale: MonitorDesign.TypeScale) -> some View {
        VStack(alignment: .leading, spacing: scale.label * 0.5) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: scale.label * 0.3) {
                    clusterLabel(group, scale: scale)
                    HStack(spacing: 3) {
                        ForEach(Array(group.loads.enumerated()), id: \.offset) { _, load in
                            HeatCell(load: load, height: max(scale.caption * 1.35, 14))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func clusterLabel(_ group: CoreGroupLoads, scale: MonitorDesign.TypeScale) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.label * 0.5) {
            Text(verbatim: group.name.uppercased())
                .font(MonitorDesign.labelFont(size: scale.label * 0.86))
                .tracking(scale.label * 0.16)
                .foregroundStyle(MonitorDesign.inkFaint)
                .opacity(0.72)
            Text(verbatim: "·\(group.loads.count)")
                .font(MonitorDesign.labelFont(size: scale.label * 0.86))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkFaint)
                .opacity(0.72)
        }
    }

    @ViewBuilder
    private func sensorRow(scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.7) {
            Spacer(minLength: 0)
            if let temp = cpuTempC { sensorReading(dot: MonitorDesign.temperatureColor(temp),
                                                    value: Self.tempValue(temp), unit: MonitorTemperature.symbol, scale: scale) }
            if let power = cpuPowerW { sensorReading(dot: MonitorDesign.signalSteel,
                                                     value: Self.powerValue(power), unit: "W", scale: scale) }
        }
    }

    @ViewBuilder
    private func sensorStrip(scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.9) {
            Text(verbatim: "SoC")
                .font(MonitorDesign.labelFont(size: scale.label))
                .tracking(MonitorDesign.labelTracking(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
            if let temp = cpuTempC { sensorReading(dot: MonitorDesign.temperatureColor(temp),
                                                   value: Self.tempValue(temp), unit: MonitorTemperature.symbol, scale: scale) }
            if cpuTempC != nil && cpuPowerW != nil {
                Text(verbatim: "·").font(MonitorDesign.captionFont(size: scale.caption)).foregroundStyle(MonitorDesign.inkFaint).opacity(0.5)
            }
            if let power = cpuPowerW { sensorReading(dot: MonitorDesign.signalSteel,
                                                     value: Self.powerValue(power), unit: "W", scale: scale) }
            Spacer(minLength: 0)
            Text(verbatim: "helper")
                .font(MonitorDesign.labelFont(size: scale.label))
                .tracking(MonitorDesign.labelTracking(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
                .opacity(0.7)
        }
        .padding(.top, scale.label * 0.4)
        .overlay(alignment: .top) {
            Rectangle().fill(MonitorDesign.hairline.opacity(0.45)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func sensorReading(dot: Color, value: String, unit: String, scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.4) {
            Circle().fill(dot)
                .frame(width: scale.label * 0.55, height: scale.label * 0.55)
                .shadow(color: dot.opacity(0.6), radius: 2)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(verbatim: value)
                    .font(MonitorDesign.subFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkPrimary)
                Text(verbatim: unit)
                    .font(MonitorDesign.captionFont(size: scale.caption * 0.7))
                    .foregroundStyle(MonitorDesign.inkFaint)
            }
        }
    }

    @ViewBuilder
    private func thermalPill(scale: MonitorDesign.TypeScale) -> some View {
        let state = system?.thermalState ?? "nominal"
        HStack(spacing: scale.label * 0.45) {
            Circle().fill(MonitorDesign.signalAmber)
                .frame(width: scale.label * 0.5, height: scale.label * 0.5)
                .shadow(color: MonitorDesign.signalAmber.opacity(0.6), radius: 2)
            Text(verbatim: "thermal")
                .font(MonitorDesign.labelFont(size: scale.label * 0.92))
                .tracking(scale.label * 0.1)
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: state.capitalized)
                .font(MonitorDesign.subFont(size: scale.label))
                .foregroundStyle(MonitorDesign.inkPrimary)
        }
        .monitorChip(scale)
    }

    @ViewBuilder
    private func procRows(_ procs: [MonitorProcessSample], scale: MonitorDesign.TypeScale) -> some View {
        let maxCPU = procs.map(\.cpuPercent).max() ?? 1
        VStack(spacing: scale.label * 0.35) {
            ForEach(Array(procs.enumerated()), id: \.offset) { _, proc in
                HStack(spacing: scale.label * 0.5) {
                    HStack(spacing: scale.label * 0.4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(MonitorDesign.inkFaint.opacity(0.7))
                            .frame(width: scale.label * 0.5, height: scale.label * 0.5)
                        Text(verbatim: proc.name)
                            .font(MonitorDesign.captionFont(size: scale.caption))
                            .foregroundStyle(MonitorDesign.inkPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    GeometryReader { g in
                        Capsule(style: .continuous).fill(MonitorDesign.track2)
                            .overlay(alignment: .leading) {
                                Capsule(style: .continuous)
                                    .fill(LinearGradient(colors: [MonitorDesign.oklch(0.6, 0.05, 78), MonitorDesign.signalAmber],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: g.size.width * CGFloat(Self.barFraction(proc.cpuPercent, maxCPU: maxCPU)))
                            }
                    }
                    .frame(width: scale.caption * 2, height: max(scale.caption * 0.42, 4))

                    Text(verbatim: Self.cpuText(proc.cpuPercent))
                        .font(MonitorDesign.subFont(size: scale.caption))
                        .monospacedDigit()
                        .foregroundStyle(MonitorDesign.signalAmber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: scale.caption * 2.1, alignment: .trailing)

                    Text(verbatim: MonitorFormat.bytes(proc.memBytes))
                        .font(MonitorDesign.captionFont(size: scale.caption * 0.94))
                        .monospacedDigit()
                        .foregroundStyle(MonitorDesign.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: scale.caption * 3.4, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func loadStatus(scale: MonitorDesign.TypeScale, triple: Bool) -> some View {
        if let text = Self.loadText(system: system, triple: triple) {
            (Text("load") + Text(verbatim: " \(text)"))
                .font(MonitorDesign.subFont(size: scale.label))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
                .monitorChip(scale)
        }
    }

    /// Identity row — device name (emphasised) + whispered core-group summary.
    @ViewBuilder
    private func identityRow(_ identity: CPUIdentity, scale: MonitorDesign.TypeScale) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.label * 0.5) {
            if let device = identity.deviceName {
                Text(verbatim: device)
                    .font(MonitorDesign.subFont(size: scale.sub * 0.92))
                    .foregroundStyle(MonitorDesign.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            if let summary = identity.coreSummary {
                Text(verbatim: "· \(summary)")
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(scale.label * 0.06)
                    .foregroundStyle(MonitorDesign.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

// MARK: - Small components

private struct HeatCell: View {
    var load: Double
    var height: CGFloat? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        let base = shape
            .fill(MonitorDesign.track2)
            .overlay(shape.fill(Self.loadColor(load)).opacity(0.32 + min(1, max(0, load)) * 0.62))
            .overlay(shape.strokeBorder(Color.black.opacity(0.3), lineWidth: 1))
            .frame(maxWidth: .infinity)
        if let height {
            base.frame(height: height)
        } else {
            base.aspectRatio(1, contentMode: .fit)
        }
    }

    /// Per-core UTILISATION ramp: green (idle) → amber → red (busy), by rotating the OKLCH hue 150°→30° with load.
    static func loadColor(_ value: Double) -> Color {
        let x = min(1, max(0, value))
        return MonitorDesign.oklch(0.72, 0.15, 150 - 120 * x)
    }
}

private struct CPUStackChart: View {
    var user: [Double]
    var system: [Double]

    var body: some View {
        GeometryReader { geo in
            let n = min(user.count, system.count)
            if n >= 2 {
                let w = geo.size.width, h = geo.size.height
                let u = Array(user.suffix(n)), s = Array(system.suffix(n))
                ZStack {
                    Canvas { ctx, size in draw(ctx, size: size, u: u, s: s, n: n) }
                    let head = min(max(u[n - 1] + s[n - 1], 0), 1)
                    Circle()
                        .fill(MonitorDesign.signalAmber)
                        .frame(width: 6, height: 6)
                        .shadow(color: MonitorDesign.signalAmber.opacity(0.6), radius: 3)
                        .position(x: w - 3, y: h - CGFloat(head) * (h - 3) - 1.5)
                }
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, u: [Double], s: [Double], n: Int) {
        let W = size.width, H = size.height
        func X(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(n - 1) * W }
        func Y(_ f: Double) -> CGFloat { H - CGFloat(min(max(f, 0), 1)) * (H - 3) - 1.5 }

        for g in [0.25, 0.5, 0.75] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: Y(g)))
            p.addLine(to: CGPoint(x: W, y: Y(g)))
            ctx.stroke(p, with: .color(MonitorDesign.hairlineHi.opacity(0.28)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        var uTop = [CGPoint](), sTop = [CGPoint]()
        for i in 0..<n {
            uTop.append(CGPoint(x: X(i), y: Y(u[i])))
            sTop.append(CGPoint(x: X(i), y: Y(u[i] + s[i])))
        }

        func area(_ tops: [CGPoint]) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: Y(0)))
            for point in tops { p.addLine(to: point) }
            p.addLine(to: CGPoint(x: W, y: Y(0)))
            p.closeSubpath()
            return p
        }
        ctx.fill(area(sTop), with: .linearGradient(
            Gradient(colors: [MonitorDesign.signalSteel.opacity(0.32), MonitorDesign.signalSteel.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: H)))
        ctx.fill(area(uTop), with: .linearGradient(
            Gradient(colors: [MonitorDesign.signalAmber.opacity(0.5), MonitorDesign.signalAmber.opacity(0.03)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: H)))

        var sLine = Path(); sLine.addLines(sTop)
        ctx.stroke(sLine, with: .color(MonitorDesign.signalSteel.opacity(0.8)),
                   style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        var uLine = Path(); uLine.addLines(uTop)
        ctx.stroke(uLine, with: .color(MonitorDesign.signalAmber),
                   style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }
}

private struct CPUStateDot: View {
    var fraction: Double

    var body: some View {
        let pct = fraction * 100
        let color: Color = pct > 85 ? MonitorDesign.signalCoral
            : (pct > 60 ? MonitorDesign.signalAmber : MonitorDesign.signalIdle)
        BreathingDot(color: color, size: 6, animated: pct > 60)
    }
}

// MARK: - Per-widget options (read side + pure draft mutations, unit-tested)

enum MonitorCPUDraft {
    static let historyWindowKey = "historyWindow"
    static let showHeatmapKey = "showHeatmap"
    static let showCompositionKey = "showComposition"
    static let showSensorsKey = "showSensors"
    static let showTrendKey = "showTrend"

    static let historyWindowChoices = [30, 60, 120]

    static func defaultHistoryWindow(for size: MonitorWidgetSize) -> Int {
        switch size {
        case .small: return 30
        case .medium: return 60
        case .large: return 120
        }
    }

    static func historyWindow(_ placement: MonitorWidgetPlacement) -> Int {
        guard let raw = placement.options[historyWindowKey]?.numberValue else {
            return defaultHistoryWindow(for: placement.size)
        }
        let value = Int(raw)
        return historyWindowChoices.contains(value) ? value : defaultHistoryWindow(for: placement.size)
    }

    static func settingHistoryWindow(_ value: Int, on placement: MonitorWidgetPlacement) -> MonitorWidgetPlacement {
        let clamped = historyWindowChoices.contains(value) ? value : defaultHistoryWindow(for: placement.size)
        var next = placement
        next.options[historyWindowKey] = .number(Double(clamped))
        return next
    }

    static func showHeatmap(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[showHeatmapKey]?.boolValue ?? true
    }

    static func settingShowHeatmap(_ value: Bool, on placement: MonitorWidgetPlacement) -> MonitorWidgetPlacement {
        var next = placement
        next.options[showHeatmapKey] = .bool(value)
        return next
    }

    static func showComposition(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[showCompositionKey]?.boolValue ?? true
    }

    static func settingShowComposition(_ value: Bool, on placement: MonitorWidgetPlacement) -> MonitorWidgetPlacement {
        var next = placement
        next.options[showCompositionKey] = .bool(value)
        return next
    }

    static func showSensors(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[showSensorsKey]?.boolValue ?? true
    }

    static func showTrend(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[showTrendKey]?.boolValue ?? true
    }

    static func settingShowSensors(_ value: Bool, on placement: MonitorWidgetPlacement) -> MonitorWidgetPlacement {
        var next = placement
        next.options[showSensorsKey] = .bool(value)
        return next
    }
}

// MARK: - Pure layout logic (tested)

extension MonitorCPUWidgetView {

    struct CPUIdentity: Equatable {
        var deviceName: String?
        var coreSummary: String?
    }

    struct CoreGroupLoads: Equatable {
        var name: String
        var loads: [Double]
    }

    nonisolated static func wholePercent(_ fraction: Double) -> String {
        "\(wholeNumber(fraction))%"
    }

    /// 0…1 → whole-number string with no "%" ("37"); same clamp/round as
    /// `wholePercent`, for callers that append their own separately-styled unit.
    nonisolated static func wholeNumber(_ fraction: Double) -> String {
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return "\(Int((f * 100).rounded()))"
    }

    nonisolated static func tempValue(_ celsius: Double) -> String {
        MonitorTemperature.valueText(celsius)
    }

    nonisolated static func powerValue(_ watts: Double) -> String {
        let w = watts.isFinite ? max(watts, 0) : 0
        return w < 10 ? String(format: "%.1f", w) : "\(Int(w.rounded()))"
    }

    nonisolated static func loadAvg(_ value: Double) -> String {
        String(format: "%.2f", value.isFinite ? max(value, 0) : 0)
    }

    /// Header load readout: 1-min average (M) or the 1·5·15 triple (L). Prefers
    /// `cpuLoadAvg`, falls back to `loadAverage1`; nil when nothing is reported.
    nonisolated static func loadText(system: MonitorSystemSnapshot?, triple: Bool) -> String? {
        guard let system else { return nil }
        if triple, let avg = system.cpuLoadAvg, !avg.isEmpty {
            return avg.prefix(3).map { loadAvg($0) }.joined(separator: " · ")
        }
        if let one = system.loadAverage1 ?? system.cpuLoadAvg?.first {
            return loadAvg(one)
        }
        return nil
    }

    /// The cpu% readout for the L attribution rows: one decimal below 10 ("0.4", "3.2") so light loads don't flatten to "0", whole number from 10 up (the `powerValue` idiom).
    nonisolated static func cpuText(_ cpuPercent: Double) -> String {
        let v = cpuPercent.isFinite ? max(cpuPercent, 0) : 0
        return v < 10 ? String(format: "%.1f", v) : "\(Int(v.rounded()))"
    }

    /// A row's cpu% over the busiest shown row → bar fill fraction 0…1.
    nonisolated static func barFraction(_ cpuPercent: Double, maxCPU: Double) -> Double {
        min(max(cpuPercent / max(maxCPU, .ulpOfOne), 0), 1)
    }

    nonisolated static func temperatureWord(_ celsius: Double) -> String {
        if celsius >= 58 { return "hot" }
        if celsius >= 48 { return "warm" }
        return "cool"
    }

    nonisolated static func compositionPercents(user: Double, system: Double) -> (user: Int, system: Int, idle: Int) {
        let u = Int((min(max(user, 0), 1) * 100).rounded())
        let s = Int((min(max(system, 0), 1) * 100).rounded())
        let idle = max(0, 100 - u - s)
        return (u, s, idle)
    }

    /// Top-k processes re-sorted by cpu% descending (stable on ties). nil in →
    /// nil out so the L attribution section collapses when there is no data.
    nonisolated static func topCPUProcesses(_ processes: [MonitorProcessSample]?, limit: Int) -> [MonitorProcessSample]? {
        guard let processes, !processes.isEmpty else { return nil }
        let sorted = processes.enumerated().sorted { lhs, rhs in
            lhs.element.cpuPercent != rhs.element.cpuPercent
                ? lhs.element.cpuPercent > rhs.element.cpuPercent
                : lhs.offset < rhs.offset
        }.map(\.element)
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Total core count across the resolved groups (for the L "Cores · N" label).
    nonisolated static func coreCountText(_ groups: [CoreGroupLoads]) -> String {
        "\(groups.reduce(0) { $0 + $1.loads.count })"
    }

    /// "Super·6 / Performance·12" cluster summary.
    nonisolated static func groupSummary(_ groups: [CoreGroupLoads]) -> String {
        groups.map { "\($0.name)·\($0.loads.count)" }.joined(separator: " / ")
    }

    /// Compose the identity line from `cpuInfo` — device name plus a core-group summary "18 cores (6 Super + 12 Performance)".
    nonisolated static func identityLine(_ info: MonitorCPUInfo?) -> CPUIdentity? {
        guard let info else { return nil }
        let device = info.deviceName.flatMap { $0.isEmpty ? nil : $0 }

        var summary: String?
        let groups = (info.coreGroups ?? []).filter { $0.physicalCount > 0 }
        let total = info.coreCount ?? (groups.isEmpty ? nil : groups.reduce(0) { $0 + $1.physicalCount })
        if let total, total > 0 {
            let noun = total == 1 ? "core" : "cores"
            if groups.isEmpty {
                summary = "\(total) \(noun)"
            } else {
                let composed = groups.map { "\($0.physicalCount) \($0.name)" }.joined(separator: " + ")
                summary = "\(total) \(noun) (\(composed))"
            }
        } else if !groups.isEmpty {
            summary = groups.map { "\($0.physicalCount) \($0.name)" }.joined(separator: " + ")
        }

        if device == nil && summary == nil { return nil }
        return CPUIdentity(deviceName: device, coreSummary: summary)
    }

    /// Slice a flat `perCore` array into the dynamic core groups declared by `coreGroups` (each group takes `physicalCount` cores, in order).
    nonisolated static func coreGroupLoads(perCore: [Double]?, cpuInfo: MonitorCPUInfo?) -> [CoreGroupLoads]? {
        guard let perCore, !perCore.isEmpty else { return nil }
        let groups = (cpuInfo?.coreGroups ?? []).filter { $0.physicalCount > 0 }
        guard !groups.isEmpty else {
            return [CoreGroupLoads(name: "CPU", loads: perCore)]
        }

        var result: [CoreGroupLoads] = []
        var offset = 0
        for group in groups {
            guard offset < perCore.count else { break }
            let end = min(offset + group.physicalCount, perCore.count)
            result.append(CoreGroupLoads(name: group.name, loads: Array(perCore[offset..<end])))
            offset = end
        }
        if offset < perCore.count {
            result.append(CoreGroupLoads(name: "CPU", loads: Array(perCore[offset...])))
        }
        return result
    }
}

// MARK: - Previews

#if DEBUG
private extension MonitorWidgetContext {
    static func cpuSample(size: MonitorWidgetSize, withSensors: Bool, showTrend: Bool = true) -> MonitorWidgetContext {
        let superLoads: [Double] = [0.71, 0.58, 0.66, 0.34, 0.52, 0.19]
        let perfLoads: [Double] = [0.44, 0.29, 0.51, 0.12, 0.38, 0.22, 0.47, 0.09, 0.33, 0.18, 0.41, 0.15]
        var sys = MonitorSystemSnapshot()
        sys.cpuTotal = 0.37
        sys.cpuUser = 0.26
        sys.cpuSystem = 0.11
        sys.perCore = superLoads + perfLoads
        sys.loadAverage1 = 3.42
        sys.cpuLoadAvg = [3.42, 2.88, 2.41]
        sys.thermalState = "fair"
        sys.cpuInfo = MonitorCPUInfo(
            deviceName: "Apple M5 Pro",
            coreCount: 18,
            coreGroups: [
                MonitorCPUCoreGroup(name: "Super", physicalCount: 6),
                MonitorCPUCoreGroup(name: "Performance", physicalCount: 12)
            ]
        )
        sys.topProcesses = [
            MonitorProcessSample(name: "Xcode", cpuPercent: 52, memBytes: UInt64(3.4 * 1_073_741_824)),
            MonitorProcessSample(name: "kernel_task", cpuPercent: 31, memBytes: UInt64(1.2 * 1_073_741_824)),
            MonitorProcessSample(name: "WindowServer", cpuPercent: 23, memBytes: 640 * 1_048_576),
            MonitorProcessSample(name: "claude (Helper)", cpuPercent: 3.2, memBytes: UInt64(1.4 * 1_073_741_824))
        ]
        if withSensors {
            sys.sensors = MonitorSensorReadings(cpuTempC: 42, cpuPowerW: 18)
        }

        let curve: [Double] = [
            0.28, 0.31, 0.35, 0.30, 0.42, 0.55, 0.48, 0.39, 0.33, 0.36,
            0.44, 0.52, 0.61, 0.47, 0.38, 0.34, 0.29, 0.33, 0.41, 0.50,
            0.58, 0.63, 0.52, 0.44, 0.37, 0.31, 0.28, 0.35, 0.43, 0.49,
            0.57, 0.51, 0.42, 0.36, 0.32, 0.30, 0.34, 0.40, 0.47, 0.53,
            0.59, 0.50, 0.41, 0.35, 0.33, 0.29, 0.32, 0.38, 0.45, 0.52,
            0.48, 0.40, 0.36, 0.34, 0.31, 0.35, 0.39, 0.44, 0.38, 0.37
        ]
        var history = MonitorHistorySnapshot()
        history.cpuTotal = curve
        history.cpuUser = curve.map { $0 * 0.7 }
        history.cpuSystem = curve.map { $0 * 0.3 }
        history.cpuPeak = 0.63

        var snapshot = MonitorSnapshot()
        snapshot.system = sys

        var placement = MonitorWidgetPlacement(kind: .cpu, size: size)
        if !showTrend { placement.options[MonitorCPUDraft.showTrendKey] = .bool(false) }

        return MonitorWidgetContext(
            snapshot: snapshot,
            history: history,
            placement: placement,
            isEditing: false,
            isAgentFleetEnabled: false,
            reduceMotion: false,
            now: Date()
        )
    }
}

#Preview("CPU · S") {
    HStack(spacing: 20) {
        MonitorCPUWidgetView(context: .cpuSample(size: .small, withSensors: false))
            .frame(width: 170, height: 170)
        MonitorCPUWidgetView(context: .cpuSample(size: .small, withSensors: true))
            .frame(width: 170, height: 170)
        MonitorCPUWidgetView(context: .cpuSample(size: .small, withSensors: true, showTrend: false))
            .frame(width: 170, height: 170)
    }
    .padding(32)
    .background(MonitorDesign.boardWash)
}

#Preview("CPU · M") {
    VStack(spacing: 20) {
        MonitorCPUWidgetView(context: .cpuSample(size: .medium, withSensors: false))
            .frame(width: 364, height: 170)
        MonitorCPUWidgetView(context: .cpuSample(size: .medium, withSensors: true))
            .frame(width: 364, height: 170)
    }
    .padding(32)
    .background(MonitorDesign.boardWash)
}

#Preview("CPU · L") {
    HStack(spacing: 20) {
        MonitorCPUWidgetView(context: .cpuSample(size: .large, withSensors: false))
            .frame(width: 364, height: 376)
        MonitorCPUWidgetView(context: .cpuSample(size: .large, withSensors: true))
            .frame(width: 364, height: 376)
    }
    .padding(32)
    .background(MonitorDesign.boardWash)
}
#endif
