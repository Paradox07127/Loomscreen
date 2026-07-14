import SwiftUI
import LiveWallpaperCore

/// GPU instrument — a native port of the mock's `gpu_s` / `gpu_m`
/// (`.claude/plan/monitor-design/index.html` §3 · GPU) laid out for Apple's
/// fixed macOS widget frames (S 170×170, M 364×170, L 364×376). The hero is the
/// shared utilisation arc (Device Utilization %); GPU is a low-frequency sample
/// (2/6/10s, user-set), so freshness is first-class and nil never renders as
/// 0% — it renders the arc's dashed "no sample" mode plus the mock's
/// unavailable copy.
///
/// Data consumed (all from `MonitorSystemSnapshot`): `gpuUsage` (hero + Device
/// line), `gpuRendererUtil` / `gpuTilerUtil` (breakdown's live numbers, either
/// may be nil), `gpuDeviceName` / `gpuCoreCount` (identity), `gpuSampledAt`
/// (freshness), `sensors.gpuTempC` / `sensors.gpuPowerW` (B-tier row, only when
/// present), `gpuMemUsedBytes` (M/L identity-row MEM chip — GPU-owned system
/// memory on Apple Silicon, hidden when nil). History comes from the sparse
/// `history.gpuDevice` / `gpuRenderer` /
/// `gpuTiler` on their shared `gpuSampleTimes` timeline plus `history.gpuPeak` —
/// the breakdown chart's Renderer/Tiler curves are the real per-sample series
/// (nil-compacted), never synthesized from the current scalar ratio.
///
/// L (§3 GPU-L is explicitly "cut" in the mock — no stable public field exists
/// to fill it: no per-core / top-k GPU process on the public
/// layer) consumes the exact same M-tier fields, re-composed for the 364×376
/// frame: ring + stacked Device/Renderer/Tiler sub-metric rows up top, then a
/// FULL-WIDTH Load chart taking the leftover height (a side-chart would come
/// out taller than wide at this aspect).
///
/// Options (`placement.options`, §3.1 GPU Settings): the read side only — the
/// popover UI itself is out of scope here.
///   - `historyWindow` (.number seconds — 30 | 60 | 120, default 60) — the Load
///     chart's trailing window on M/L, mirrors the settings' 30s/60s/120s
///     segmented control. Off-catalog values fall back to 60.
///   - `showLoadBreakdown` (.bool, default true) — the Device/Renderer/Tiler
///     breakdown, the compute-gap chip and the honest note. Off degrades the
///     Load chart to a solo Device curve (mock: "Optional 缺失降单线") rather
///     than hiding the whole card.
///   - `showSensors` (.bool, default true) — per-card visibility of ALREADY
///     unlocked B-tier readings; this does NOT perform the Pro/helper unlock
///     itself (that flow is global, §5.1) — off just hides the row/capsule on
///     this card even when sensor data is present.
///   - `showTrend` (.bool, default true) — S's history sparkline; off frees
///     that height back to the arc (the peak still reads on the arc's marker).
///   - `gpuSampleSeconds` (.number, 2|6|10, default 6) — the sampler's period,
///     plumbed centrally; read here only to scale the staleness threshold
///     (~2× period with the legacy 15s floor) so a 10s cadence can't flap.
///   - `showRendererFootprint` — deferred/opt-in (`MTLDevice.
///     currentAllocatedSize` self-diagnostics, shown disabled/"即将推出" in
///     both settings variants). No backing data field exists yet, so this
///     widget does not read it.
struct MonitorGPUWidgetView: View {
    let context: MonitorWidgetContext

    init(context: MonitorWidgetContext) {
        self.context = context
    }

    var body: some View {
        GeometryReader { geo in
            // The board hands us the final Apple-exact frame. S/M are one board
            // row tall, L two; cellH = frameH/(2·rowSpan) → S/M 85, L 94, so all
            // sizes share ~one type scale and L buys layout room, not bigger text.
            let rowSpan: CGFloat = context.placement.size == .large ? 2 : 1
            GPUWidgetBody(context: context, cellHeight: geo.size.height / (2 * rowSpan))
        }
    }

    // MARK: - Pure logic (tested)

    /// Snaps a `historyWindow` option to the settings' supported {30, 60, 120}s
    /// catalog, defaulting to 60s (the mock's segmented-control default) for
    /// anything absent or off-catalog — a corrupt/future value can't produce a
    /// nonsensical window.
    nonisolated static func resolvedHistoryWindowSeconds(_ raw: Double?) -> Double {
        guard let raw, [30.0, 60.0, 120.0].contains(raw) else { return 60 }
        return raw
    }

    /// Load state dot: crit >0.85, warm >0.60, else none (transparent). Mirrors
    /// the mock's `gpuStateDot` thresholds (shared with CPU).
    nonisolated static func stateDotColor(_ pct: Double) -> Color {
        if pct > 0.85 { return MonitorDesign.signalCoral }
        if pct > 0.60 { return MonitorDesign.signalAmber }
        return MonitorDesign.signalIdle.opacity(0.6)
    }

    /// Compute ≈ Device − Renderer, clamped ≥ 0, as a whole percent. nil when
    /// either input is missing (the gap is undefined without both).
    nonisolated static func computePercent(device: Double?, renderer: Double?) -> Int? {
        guard let device, let renderer else { return nil }
        let gap = max(0, device - renderer)
        return Int((gap * 100).rounded())
    }

    /// Freshness age in whole seconds since the GPU sample timestamp (epoch).
    nonisolated static func freshnessSeconds(sampledAt: Double?, now: Date) -> Double? {
        guard let sampledAt, sampledAt > 0 else { return nil }
        return max(0, now.timeIntervalSince1970 - sampledAt)
    }

    /// "Ns ago" text via the shared `.ago` formatter; "—" when unknown.
    nonisolated static func freshnessText(sampledAt: Double?, now: Date) -> String {
        guard let age = freshnessSeconds(sampledAt: sampledAt, now: now) else { return "—" }
        return MonitorFormat.ago(age)
    }

    /// Stale once the sample is older than ~15s (GPU polls ~6s; ~15s ≈ 2+ missed
    /// samples). Unknown timestamps read as stale so we never imply freshness.
    nonisolated static func isStale(sampledAt: Double?, now: Date) -> Bool {
        guard let age = freshnessSeconds(sampledAt: sampledAt, now: now) else { return true }
        return age > 15
    }

    /// Period-aware stale threshold: 2× the configured sampling period with the
    /// legacy 15s floor — the 6s default keeps the pinned 15s behaviour and a
    /// 10s period gets 20s, so one late sample can't flap the freshness chip.
    nonisolated static func staleThresholdSeconds(samplePeriod: Double?) -> Double {
        guard let samplePeriod, samplePeriod > 0 else { return 15 }
        return max(15, samplePeriod * 2)
    }

    nonisolated static func isStale(sampledAt: Double?, now: Date, samplePeriod: Double?) -> Bool {
        guard let age = freshnessSeconds(sampledAt: sampledAt, now: now) else { return true }
        return age > staleThresholdSeconds(samplePeriod: samplePeriod)
    }

    /// Temperature word band (mock `tempLabel`): hot ≥58, warm ≥48, else cool.
    nonisolated static func tempLabel(_ celsius: Double) -> String {
        if celsius >= 58 { return "hot" }
        if celsius >= 48 { return "warm" }
        return "cool"
    }

    /// Windows a sparse, aligned `[Double?]` series (one entry per `times`,
    /// nil where that poll lacked the key) to the last `windowSeconds` and drops
    /// the nils. Fewer than 2 real points surviving → nil (curve absent) rather
    /// than a single dot or a fabricated line.
    nonisolated static func compactedSeries(_ series: [Double?], times: [Double],
                                             windowSeconds: Double) -> [Double]? {
        guard series.count == times.count, let last = times.last else { return nil }
        let cutoff = last - windowSeconds
        let real = zip(times, series)
            .filter { $0.0 >= cutoff }
            .compactMap { $0.1 }
        return real.count >= 2 ? real : nil
    }
}

// MARK: - Body (cell-height threaded)

private struct GPUWidgetBody: View {
    let context: MonitorWidgetContext
    let cellHeight: CGFloat

    private var system: MonitorSystemSnapshot? { context.snapshot.system }
    private var gpuUsage: Double? { system?.gpuUsage }
    private var scale: MonitorDesign.TypeScale { .init(cellHeight: cellHeight) }

    var body: some View {
        MonitorWidgetContainer(
            label: "GPU",
            cellHeight: cellHeight,
            status: { statusAccessory }
        ) {
            switch context.placement.size {
            case .small: smallBody
            case .medium: mediumBody
            case .large: largeBody
            }
        }
    }

    // MARK: - Header accessory
    //
    // S shows only a load state dot (warm >60 / crit >85). M/L show the freshness
    // chip ("Ns ago" + hollow ring, dimmed when stale) — GPU's low-freq honesty.

    @ViewBuilder
    private var statusAccessory: some View {
        switch context.placement.size {
        case .small:
            if gpuUsage == nil {
                Text(verbatim: "n/a")
                    .tracking(0.5)
                    .foregroundStyle(MonitorDesign.inkFaint)
            } else {
                stateDot
            }
        case .medium, .large:
            if gpuUsage == nil {
                Text(verbatim: "n/a")
                    .tracking(0.5)
                    .foregroundStyle(MonitorDesign.inkFaint)
            } else {
                HStack(spacing: 6) {
                    freshnessChip
                    stateDot
                }
            }
        }
    }

    @ViewBuilder
    private var stateDot: some View {
        let pct = gpuUsage ?? 0
        Circle()
            .fill(MonitorGPUWidgetView.stateDotColor(pct))
            .frame(width: 6, height: 6)
    }

    private var freshnessChip: some View {
        let stale = MonitorGPUWidgetView.isStale(sampledAt: system?.gpuSampledAt, now: context.now,
                                                 samplePeriod: gpuSamplePeriodSeconds)
        let color = stale ? MonitorDesign.staleWarm : MonitorDesign.inkFaint
        return HStack(spacing: 4) {
            Circle()
                .strokeBorder(stale ? MonitorDesign.staleWarm : MonitorDesign.signalSteel,
                              lineWidth: 1.5)
                .frame(width: 6, height: 6)
                .opacity(stale ? 0.85 : 0.7)
            // "sampled" / "ago" are words (localized); the age between them is data.
            (Text("sampled") + Text(verbatim: " ")
             + Text(verbatim: MonitorGPUWidgetView.freshnessText(sampledAt: system?.gpuSampledAt, now: context.now))
                .foregroundStyle(MonitorDesign.inkMuted)
             + Text(verbatim: " ") + Text("ago"))
                .font(MonitorDesign.labelFont(size: scale.label * 0.96))
        }
        .foregroundStyle(color)
        .lineLimit(1)
    }

    // MARK: - S (170×170 → content ≈ 138×125)
    //
    // Budget: temp chip ~16 + trend ~20 + spacings ~10 leave the arc ~79pt with
    // sensors (~104 without) — the ring is height-bound, never width-bound.

    @ViewBuilder
    private var smallBody: some View {
        if gpuUsage == nil {
            unavailableBody
        } else {
            let pct = gpuUsage ?? 0
            let hasTemp = tempC != nil && showSensorsPreference
            VStack(spacing: scale.label * 0.55) {
                ArcGauge(value: pct, peak: peakFraction, lineWidth: 9) {
                    arcCenter(scale: hasTemp ? 0.9 : 1)
                }
                .frame(maxWidth: 138)
                .frame(maxHeight: .infinity)

                if hasTemp, let t = tempC {
                    temperatureCapsule(t)
                }

                // Peak reads in the trend's top-right corner (a chip), not its own
                // row. `showTrend` off drops the whole block and the flexible arc
                // above recentres into the freed height.
                if showTrend {
                    Sparkline(values: history30, domain: 0...1, bandColored: true)
                        .frame(height: max(cellHeight * 0.24, 20))
                        .overlay(alignment: .topTrailing) {
                            peakTag(size: scale.label * 0.9).padding(2)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// nil GPU → the honest unavailable state (mock `gpu_s_unavailable`): a dashed
    /// hollow arc, an em-dash where the hero% sits, a "GPU" label, and a caption.
    private var unavailableBody: some View {
        VStack(spacing: scale.label * 0.6) {
            ArcGauge(value: nil, lineWidth: 9) {
                VStack(spacing: 1) {
                    Text(verbatim: "—")
                        .font(MonitorDesign.heroFont(size: scale.hero * 1.02))
                        .foregroundStyle(MonitorDesign.naval)
                    Text(verbatim: "GPU")
                        .font(MonitorDesign.labelFont(size: scale.label * 0.94))
                        .tracking(scale.label * 0.14)
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
            }
            .frame(maxWidth: 138)
            .frame(maxHeight: .infinity)

            Text("no sample — utilisation source unavailable")
                .font(MonitorDesign.captionFont(size: scale.caption))
                .foregroundStyle(MonitorDesign.inkFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - M (364×170 → content ≈ 332×125)
    //
    // Fixed rows (identity ~18 + legend ~15 + sensors ~15 + spacings ~14) leave
    // the ring/chart row ~63pt, so: the compute chip lives ON the legend row
    // (not its own line above the chart), and the honest gap note only appears
    // when the sensor row is absent — both can't fit a 125pt box.

    @ViewBuilder
    private var mediumBody: some View {
        if gpuUsage == nil {
            unavailableBody
        } else {
            VStack(alignment: .leading, spacing: scale.label * 0.5) {
                if hasIdentity || memUsedBytes != nil { identityRow }

                HStack(alignment: .center, spacing: scale.label) {
                    // Arc hugs the left edge; its side follows the row height
                    // (min(width, rowH)) so the load chart takes the freed width.
                    ArcGauge(value: gpuUsage ?? 0, peak: peakFraction, lineWidth: 9) {
                        arcCenter(scale: 0.8)
                    }
                    .frame(width: 68, alignment: .leading)

                    loadChart(minHeight: 30, peakScale: 0.86)
                }
                .frame(maxHeight: .infinity)

                if showLoadBreakdown {
                    legendRow
                }
                if let row = sensorRow {
                    row
                } else if showLoadBreakdown {
                    computeGapNote
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - L (364×376 → content ≈ 332×331)
    //
    // Same fields as M (see the type doc's "cut" note) re-composed for the tall
    // frame: identity, then ring + stacked sub-metric rows (values right-aligned,
    // single-line), then a full-width Load chart flexing into the leftover
    // ~150pt, the honest note, and the sensor strip.

    @ViewBuilder
    private var largeBody: some View {
        if gpuUsage == nil {
            unavailableBody
        } else {
            VStack(alignment: .leading, spacing: scale.label * 0.7) {
                if hasIdentity || memUsedBytes != nil { identityRow }

                HStack(alignment: .center, spacing: scale.label * 1.2) {
                    ArcGauge(value: gpuUsage ?? 0, peak: peakFraction, lineWidth: 9) {
                        arcCenter(scale: 0.92)
                    }
                    .frame(width: 108, alignment: .leading)

                    if showLoadBreakdown {
                        VStack(alignment: .leading, spacing: scale.label * 0.55) {
                            subMetricRow(name: "Device", value: gpuUsage,
                                         color: MonitorDesign.inkPrimary, dashed: false)
                            if let r = system?.gpuRendererUtil {
                                subMetricRow(name: "Renderer", value: r,
                                             color: MonitorDesign.signalSteel, dashed: false)
                            }
                            if let t = system?.gpuTilerUtil {
                                subMetricRow(name: "Tiler", value: t,
                                             color: MonitorDesign.tilerViolet, dashed: true)
                            }
                            computeChip
                                .padding(.top, scale.label * 0.3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity)

                loadChart(minHeight: 90, peakScale: 0.96)

                if showLoadBreakdown {
                    computeGapNote
                }
                if let row = sensorRow {
                    row
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Shared sections

    private var hasIdentity: Bool {
        (system?.gpuDeviceName?.isEmpty == false) || system?.gpuCoreCount != nil
    }

    /// "<gpuDeviceName> · N-core GPU" — mirrors the mock's whispered identity
    /// line — with the MEM chip (GPU-owned system memory, when known) whispered
    /// on its trailing edge; utilization stays the hero.
    private var identityRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let name = system?.gpuDeviceName, !name.isEmpty {
                Text(verbatim: name)
                    .font(MonitorDesign.subFont(size: scale.sub * 0.92))
                    .foregroundStyle(MonitorDesign.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let cores = system?.gpuCoreCount {
                // "N-core GPU" reads as language; the count is data (a placeholder).
                Text(verbatim: String(localized: "· \(cores)-core GPU",
                                      comment: "GPU widget identity: GPU core count; %lld is the number of cores."))
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(scale.label * 0.06)
                    .foregroundStyle(MonitorDesign.inkFaint)
                    .lineLimit(1)
            }
            if let mem = memUsedBytes {
                Spacer(minLength: 6)
                memChip(mem)
            }
        }
    }

    private func memChip(_ bytes: UInt64) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: "MEM")
                .font(MonitorDesign.labelFont(size: scale.label))
                .tracking(scale.label * 0.1)
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: MonitorFormat.bytes(bytes))
                .font(MonitorDesign.labelFont(size: scale.label))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
        }
        .lineLimit(1)
    }

    /// The Load breakdown chart with the board's peak tag pinned in its top-right
    /// corner. `Renderer`/`Tiler` drop out entirely (a solo Device curve) when
    /// `showLoadBreakdown` is off.
    private func loadChart(minHeight: CGFloat, peakScale: CGFloat) -> some View {
        GPUBreakdownChart(
            device: historyWindowed,
            renderer: effectiveRendererHistory,
            tiler: effectiveTilerHistory,
            reduceMotion: context.reduceMotion
        )
        .frame(maxWidth: .infinity)
        .frame(minHeight: minHeight, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            peakTag(size: scale.label * peakScale).padding(3)
        }
    }

    /// The compute-gap chip — reads Device − Renderer as an ≈ compute estimate.
    /// Only shown when both Device and Renderer are known (the gap is undefined
    /// otherwise — the mock only renders it in the full-data path).
    @ViewBuilder
    private var computeChip: some View {
        if let compute = MonitorGPUWidgetView.computePercent(device: gpuUsage,
                                                             renderer: system?.gpuRendererUtil) {
            HStack(spacing: 5) {
                Text("compute")
                    .font(MonitorDesign.labelFont(size: scale.label * 0.9))
                    .tracking(scale.label * 0.1)
                    .foregroundStyle(MonitorDesign.inkFaint)
                Text(verbatim: "≈\(compute)%")
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.computeViolet)
            }
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(MonitorDesign.computeChipStroke,
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
            .background(Capsule(style: .continuous).fill(MonitorDesign.computeChipFill))
        }
    }

    /// M's one-line legend: Device / Renderer / Tiler swatches + live values with
    /// the compute chip on the same row's trailing edge. A nil util omits that
    /// line and the row compacts (mock: "Optional 缺失降单线").
    private var legendRow: some View {
        HStack(spacing: scale.label * 1.1) {
            legendItem(name: "Device", value: gpuUsage,
                       color: MonitorDesign.inkPrimary, dashed: false)
            if system?.gpuRendererUtil != nil {
                legendItem(name: "Renderer", value: system?.gpuRendererUtil,
                           color: MonitorDesign.signalSteel, dashed: false)
            }
            if system?.gpuTilerUtil != nil {
                legendItem(name: "Tiler", value: system?.gpuTilerUtil,
                           color: MonitorDesign.tilerViolet, dashed: true)
            }
            Spacer(minLength: 4)
            computeChip
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func legendItem(name: String, value: Double?, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            SwatchLine(color: color, dashed: dashed)
                .frame(width: 12, height: 3)
            Text(verbatim: name.uppercased())
                .font(MonitorDesign.labelFont(size: scale.label))
                .tracking(scale.label * 0.1)
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: MonitorFormat.percent(value ?? 0))
                .font(MonitorDesign.labelFont(size: scale.label))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
        }
    }

    /// L's stacked sub-metric row beside the ring — swatch + whisper name, value
    /// right-aligned against the content edge. Always single-line.
    private func subMetricRow(name: String, value: Double?, color: Color, dashed: Bool) -> some View {
        HStack(spacing: scale.label * 0.55) {
            SwatchLine(color: color, dashed: dashed)
                .frame(width: 14, height: 3)
            Text(verbatim: name.uppercased())
                .font(MonitorDesign.labelFont(size: scale.label))
                .tracking(scale.label * 0.1)
                .foregroundStyle(MonitorDesign.inkFaint)
            Spacer(minLength: 4)
            Text(verbatim: MonitorFormat.percent(value ?? 0))
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// The honest gap annotation (mock's `.cap` line under the legend).
    private var computeGapNote: some View {
        Text("Device − Renderer gap ≈ compute (Metal / GPU ML) load")
            .font(MonitorDesign.captionFont(size: scale.caption))
            .foregroundStyle(MonitorDesign.inkFaint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// B-tier sensor strip (M and L) — temp (cool→warm dot) + power (steel dot).
    /// The frozen contract carries no GPU frequency, so unlike the mock this row
    /// shows temp + power only. Absent when `showSensors` is off or neither
    /// sensor is present.
    private var sensorRow: (some View)? {
        guard showSensorsPreference else { return Optional<AnyView>.none }
        let t = tempC
        let p = system?.sensors?.gpuPowerW
        guard t != nil || p != nil else { return Optional<AnyView>.none }
        return AnyView(
            HStack(spacing: 10) {
                Text(verbatim: "GPU")
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(scale.label * 0.12)
                    .foregroundStyle(MonitorDesign.inkFaint)
                if let t {
                    sensorReading(dotColor: MonitorDesign.temperatureColor(t),
                                  glow: true,
                                  value: MonitorTemperature.valueText(t), unit: MonitorTemperature.symbol)
                }
                if t != nil && p != nil {
                    Text(verbatim: "·").foregroundStyle(MonitorDesign.inkFaint.opacity(0.5))
                }
                if let p {
                    sensorReading(dotColor: MonitorDesign.signalSteel,
                                  glow: true,
                                  value: "\(Int(p.rounded()))", unit: "W")
                }
                Spacer(minLength: 0)
                Text("helper")
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(scale.label * 0.1)
                    .foregroundStyle(MonitorDesign.inkFaint.opacity(0.7))
            }
            .lineLimit(1)
            .padding(.top, 3)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(MonitorDesign.hairline.opacity(0.5))
                    .frame(height: MonitorDesign.hairlineWidth)
            }
        )
    }

    private func sensorReading(dotColor: Color, glow: Bool, value: String, unit: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .shadow(color: glow ? dotColor.opacity(0.7) : .clear, radius: glow ? 3 : 0)
            (Text(verbatim: value)
             + Text(verbatim: unit)
                .font(MonitorDesign.labelFont(size: scale.label * 0.7))
                .foregroundStyle(MonitorDesign.inkFaint))
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
        }
    }

    // MARK: - Shared pieces

    private func arcCenter(scale factor: CGFloat) -> some View {
        let pct = Int(((gpuUsage ?? 0) * 100).rounded())
        return HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(verbatim: "\(pct)")
                .font(MonitorDesign.heroFont(size: scale.hero * factor))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
            Text(verbatim: "%")
                .font(MonitorDesign.labelFont(size: scale.hero * factor * 0.5))
                .foregroundStyle(MonitorDesign.inkFaint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private func peakTag(size: CGFloat) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(MonitorDesign.peakMarker)
                .frame(width: 5, height: 5)
                .opacity(0.85)
            Text("peak")
                .font(MonitorDesign.labelFont(size: size))
                .tracking(size * 0.12)
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: "\(peakPercent)%")
                .font(MonitorDesign.labelFont(size: size))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
        }
        .monitorChip(scale)
    }

    private func temperatureCapsule(_ t: Double) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(MonitorDesign.temperatureColor(t))
                .frame(width: 7, height: 7)
                .shadow(color: MonitorDesign.temperatureColor(t).opacity(0.6), radius: 3)
            (Text(verbatim: MonitorTemperature.valueText(t))
             + Text(verbatim: MonitorTemperature.symbol)
                .font(MonitorDesign.labelFont(size: scale.caption * 0.68))
                .foregroundStyle(MonitorDesign.inkFaint))
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
            // Temperature band word (cool/warm/hot), localized then uppercased for
            // display (the case transform is a no-op for non-Latin scripts).
            Text(LocalizedStringKey(MonitorGPUWidgetView.tempLabel(t)))
                .font(MonitorDesign.labelFont(size: scale.label * 0.94))
                .tracking(scale.label * 0.12)
                .foregroundStyle(MonitorDesign.inkFaint)
                .textCase(.uppercase)
        }
        .monitorChip(scale)
    }

    // MARK: - Derived values

    private var tempC: Double? { system?.sensors?.gpuTempC }

    private var memUsedBytes: UInt64? { system?.gpuMemUsedBytes }

    private var peakFraction: Double? {
        let p = context.history.gpuPeak
        return p > 0 ? p : nil
    }

    private var peakPercent: Int { Int((max(context.history.gpuPeak, gpuUsage ?? 0) * 100).rounded()) }

    /// Last ~30s of GPU device samples. GPU is sparse (~6s), so 30s ≈ the last 5
    /// real samples on the GPU timeline; slice by `gpuSampleTimes`. Fixed at 30s
    /// (the mock's S trend is not `historyWindow`-configurable — that setting
    /// only governs the M/L Load chart).
    private var history30: [Double] { gpuHistory(windowSeconds: 30) }
    /// The M/L Load chart's device curve, windowed by `historyWindowSeconds`.
    private var historyWindowed: [Double] { gpuHistory(windowSeconds: historyWindowSeconds) }

    private func gpuHistory(windowSeconds: Double) -> [Double] {
        let device = context.history.gpuDevice
        let times = context.history.gpuSampleTimes
        guard !device.isEmpty else { return [] }
        guard times.count == device.count, let last = times.last else { return device }
        let cutoff = last - windowSeconds
        let sliced = zip(times, device).filter { $0.0 >= cutoff }.map { $0.1 }
        return sliced.isEmpty ? [device[device.count - 1]] : sliced
    }

    /// Real Renderer/Tiler samples over the Load window, aligned with
    /// `gpuSampleTimes` (nil where that poll lacked the key). Fewer than 2 real
    /// points in the window → the curve is absent rather than drawn from
    /// synthesized data; the legend still carries the exact live numbers
    /// regardless.
    private var rendererHistory: [Double]? {
        MonitorGPUWidgetView.compactedSeries(context.history.gpuRenderer,
                                             times: context.history.gpuSampleTimes,
                                             windowSeconds: historyWindowSeconds)
    }

    private var tilerHistory: [Double]? {
        MonitorGPUWidgetView.compactedSeries(context.history.gpuTiler,
                                             times: context.history.gpuSampleTimes,
                                             windowSeconds: historyWindowSeconds)
    }

    /// `nil` (dropping the compute-gap band + line) once `showLoadBreakdown` is
    /// off, even when real Renderer/Tiler samples exist — the setting hides the
    /// breakdown, not just the legend text.
    private var effectiveRendererHistory: [Double]? { showLoadBreakdown ? rendererHistory : nil }
    private var effectiveTilerHistory: [Double]? { showLoadBreakdown ? tilerHistory : nil }

    // MARK: - Settings read side (placement.options, §3.1 GPU Settings)

    private var historyWindowSeconds: Double {
        MonitorGPUWidgetView.resolvedHistoryWindowSeconds(context.placement.options["historyWindow"]?.numberValue)
    }

    private var showLoadBreakdown: Bool {
        context.placement.options["showLoadBreakdown"]?.boolValue ?? true
    }

    private var showSensorsPreference: Bool {
        context.placement.options["showSensors"]?.boolValue ?? true
    }

    private var showTrend: Bool {
        context.placement.options["showTrend"]?.boolValue ?? true
    }

    /// The sampler's configured period (2/6/10s picker); nil = the 6s default
    /// (the settings side drops the key at default). Only feeds the staleness
    /// threshold — the sampling itself is plumbed centrally.
    private var gpuSamplePeriodSeconds: Double? {
        context.placement.options["gpuSampleSeconds"]?.numberValue
    }
}

// MARK: - Breakdown chart
//
// Device (ink, filled envelope) over Renderer (steel) over Tiler (violet dashed),
// with the Device→Renderer band faintly violet-tinted as the visible "compute"
// region. Ports the mock's `gpuBreakdownChart`. Renderer/Tiler are optional: a
// nil series drops that line (and the compute band if Renderer is gone).
private struct GPUBreakdownChart: View {
    var device: [Double]
    var renderer: [Double]?
    var tiler: [Double]?
    var reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if device.count >= 2 {
                ZStack {
                    ForEach([0.25, 0.5, 0.75], id: \.self) { g in
                        let y = yFor(g, h: h)
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(MonitorDesign.hairlineHi.opacity(0.26), lineWidth: 1)
                    }

                    // Device area envelope (ink-tinted, down to baseline).
                    areaPath(device, w: w, h: h)
                        .fill(LinearGradient(
                            colors: [MonitorDesign.inkPrimary.opacity(0.16),
                                     MonitorDesign.inkPrimary.opacity(0.01)],
                            startPoint: .top, endPoint: .bottom))

                    // Compute-gap band: between Device and Renderer.
                    if let renderer, renderer.count == device.count {
                        gapBand(device: device, renderer: renderer, w: w, h: h)
                            .fill(LinearGradient(
                                colors: [MonitorDesign.computeViolet.opacity(0.24),
                                         MonitorDesign.computeViolet.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom))
                    }

                    if let tiler, tiler.count == device.count {
                        linePath(tiler, w: w, h: h)
                            .stroke(MonitorDesign.tilerViolet.opacity(0.85),
                                    style: StrokeStyle(lineWidth: 1.3, lineJoin: .round, dash: [4, 3]))
                    }
                    if let renderer, renderer.count == device.count {
                        linePath(renderer, w: w, h: h)
                            .stroke(MonitorDesign.signalSteel,
                                    style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    }
                    linePath(device, w: w, h: h)
                        .stroke(MonitorDesign.inkPrimary,
                                style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))

                    if let last = device.last {
                        Circle()
                            .fill(MonitorDesign.inkPrimary)
                            .frame(width: 5, height: 5)
                            .position(x: w, y: yFor(last, h: h))
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: device)
            }
        }
    }

    private func yFor(_ f: Double, h: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, f))
        return h - CGFloat(clamped) * (h - 4) - 2
    }

    private func xFor(_ i: Int, count: Int, w: CGFloat) -> CGFloat {
        count <= 1 ? w : CGFloat(i) / CGFloat(count - 1) * w
    }

    private func linePath(_ arr: [Double], w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        for (i, v) in arr.enumerated() {
            let pt = CGPoint(x: xFor(i, count: arr.count, w: w), y: yFor(v, h: h))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    private func areaPath(_ arr: [Double], w: CGFloat, h: CGFloat) -> Path {
        var p = linePath(arr, w: w, h: h)
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }

    private func gapBand(device: [Double], renderer: [Double], w: CGFloat, h: CGFloat) -> Path {
        var p = linePath(device, w: w, h: h)
        for i in stride(from: renderer.count - 1, through: 0, by: -1) {
            p.addLine(to: CGPoint(x: xFor(i, count: renderer.count, w: w), y: yFor(renderer[i], h: h)))
        }
        p.closeSubpath()
        return p
    }
}

/// A tiny legend swatch — a solid or dashed top-border rule, matching the mock's
/// `.glegend .sw`.
private struct SwatchLine: View {
    var color: Color
    var dashed: Bool

    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round,
                                              dash: dashed ? [3, 2] : []))
        }
    }
}

// MARK: - GPU-specific palette
//
// Extra tokens the shared MonitorDesign doesn't expose, ported 1:1 from the
// mock's GPU section (`oklch(...)` literals in index.html).
private extension MonitorDesign {
    /// `.naval` — the em-dash "no reading" numeral colour.
    static let naval = oklch(0.5, 0.012, 76)
    /// Tiler line / breakdown violet — `oklch(0.66 0.09 300)`.
    static let tilerViolet = oklch(0.66, 0.09, 300)
    /// Compute-gap fill/text violet — `oklch(0.66 0.09 300)` band, `0.82 0.07 300` text.
    static let computeViolet = oklch(0.82, 0.07, 300)
    static let computeChipStroke = oklch(0.5, 0.06, 300, alpha: 0.6)
    static let computeChipFill = oklch(0.24, 0.02, 300, alpha: 0.28)
    /// Peak marker square — `oklch(0.72 0.09 60)`.
    static let peakMarker = oklch(0.72, 0.09, 60)
    /// Freshness "stale" warm — `oklch(0.6 0.05 60)`.
    static let staleWarm = oklch(0.6, 0.05, 60)
}

// MARK: - Previews

#if DEBUG
private func gpuPreviewContext(
    size: MonitorWidgetSize,
    gpuUsage: Double?,
    withSensors: Bool = false,
    staleSeconds: Double = 4,
    device: String? = "Apple M5 Pro",
    cores: Int? = 20,
    options: [String: MonitorWidgetOptionValue] = [:]
) -> MonitorWidgetContext {
    let now = Date()
    var sys = MonitorSystemSnapshot()
    sys.gpuUsage = gpuUsage
    sys.gpuRendererUtil = gpuUsage.map { min(1, $0 * 0.79) }
    sys.gpuTilerUtil = gpuUsage.map { min(1, $0 * 0.65) }
    sys.gpuDeviceName = device
    sys.gpuCoreCount = cores
    sys.gpuMemUsedBytes = gpuUsage != nil ? 1_288_490_189 : nil   // ≈1.2 GB
    sys.gpuSampledAt = now.timeIntervalSince1970 - staleSeconds
    if withSensors {
        var sensors = MonitorSensorReadings()
        sensors.gpuTempC = 62
        sensors.gpuPowerW = 24
        sys.sensors = sensors
    }

    var history = MonitorHistorySnapshot()
    let curve: [Double] = [0.18, 0.22, 0.20, 0.25, 0.31, 0.28, 0.24, 0.20, 0.26, 0.33,
                           0.29, 0.23, 0.19, 0.24, 0.30, 0.27, 0.21, 0.52]
    if gpuUsage != nil {
        history.gpuDevice = curve
        history.gpuSampleTimes = curve.indices.map { now.timeIntervalSince1970 - Double(curve.count - 1 - $0) * 6 }
        history.gpuPeak = 0.82
        // Real per-sample Renderer/Tiler, mirroring the ~0.79/0.65 device ratio;
        // one dropped poll (nil) to exercise the honest gap-compaction path.
        history.gpuRenderer = curve.enumerated().map { i, v in i == 3 ? nil : min(1, v * 0.79) }
        history.gpuTiler = curve.enumerated().map { i, v in i == 3 ? nil : min(1, v * 0.65) }
    }

    var snapshot = MonitorSnapshot()
    snapshot.timestamp = now.timeIntervalSince1970
    snapshot.system = sys

    return MonitorWidgetContext(
        snapshot: snapshot,
        history: history,
        placement: MonitorWidgetPlacement(kind: .gpu, size: size, options: options),
        isEditing: false,
        isAgentFleetEnabled: false,
        reduceMotion: false,
        now: now
    )
}

#Preview("GPU · S") {
    HStack(spacing: 20) {
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .small, gpuUsage: 0.52))
            .frame(width: 170, height: 170)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .small, gpuUsage: 0.52, withSensors: true))
            .frame(width: 170, height: 170)
        // showTrend = false → sparkline gone, arc recentres in the freed height.
        MonitorGPUWidgetView(context: gpuPreviewContext(
            size: .small, gpuUsage: 0.52, withSensors: true,
            options: ["showTrend": .bool(false)]))
            .frame(width: 170, height: 170)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .small, gpuUsage: nil))
            .frame(width: 170, height: 170)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("GPU · M") {
    VStack(spacing: 20) {
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .medium, gpuUsage: 0.52))
            .frame(width: 364, height: 170)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .medium, gpuUsage: 0.52, withSensors: true, staleSeconds: 4))
            .frame(width: 364, height: 170)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .medium, gpuUsage: 0.88, staleSeconds: 22))
            .frame(width: 364, height: 170)
        // 10s sampling period → threshold 20s, so an 18s-old sample is NOT stale.
        MonitorGPUWidgetView(context: gpuPreviewContext(
            size: .medium, gpuUsage: 0.52, staleSeconds: 18,
            options: ["gpuSampleSeconds": .number(10)]))
            .frame(width: 364, height: 170)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .medium, gpuUsage: nil))
            .frame(width: 364, height: 170)
        // showLoadBreakdown = false → solo Device curve, no legend/gap chip/note.
        MonitorGPUWidgetView(context: gpuPreviewContext(
            size: .medium, gpuUsage: 0.52,
            options: ["showLoadBreakdown": .bool(false)]))
            .frame(width: 364, height: 170)
        // showSensors = false with real sensor data present → row stays hidden.
        MonitorGPUWidgetView(context: gpuPreviewContext(
            size: .medium, gpuUsage: 0.52, withSensors: true,
            options: ["showSensors": .bool(false)]))
            .frame(width: 364, height: 170)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("GPU · L") {
    HStack(spacing: 20) {
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .large, gpuUsage: 0.52))
            .frame(width: 364, height: 376)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .large, gpuUsage: 0.52, withSensors: true))
            .frame(width: 364, height: 376)
        // historyWindow = 120s → the settings' longest window on the taller chart.
        MonitorGPUWidgetView(context: gpuPreviewContext(
            size: .large, gpuUsage: 0.68, withSensors: true,
            options: ["historyWindow": .number(120)]))
            .frame(width: 364, height: 376)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .large, gpuUsage: nil))
            .frame(width: 364, height: 376)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}
#endif
