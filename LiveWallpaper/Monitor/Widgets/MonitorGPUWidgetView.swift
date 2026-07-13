import SwiftUI
import LiveWallpaperCore

/// GPU instrument — a 1:1 native port of the mock's `gpu_s` / `gpu_m`
/// (`.claude/plan/monitor-design/index.html` §3 · GPU). The hero is the shared
/// utilisation arc (Device Utilization %); GPU is a ~6s low-frequency sample, so
/// freshness is first-class and nil never renders as 0% — it renders the arc's
/// dashed "no sample" mode plus the mock's unavailable copy.
///
/// Data consumed (all from `MonitorSystemSnapshot`): `gpuUsage` (hero + Device
/// line), `gpuRendererUtil` / `gpuTilerUtil` (legend's live numbers, either may
/// be nil), `gpuDeviceName` / `gpuCoreCount` (identity), `gpuSampledAt`
/// (freshness), `sensors.gpuTempC` / `sensors.gpuPowerW` (B-tier row, only when
/// present). History comes from the sparse `history.gpuDevice` / `gpuRenderer` /
/// `gpuTiler` on their shared `gpuSampleTimes` timeline plus `history.gpuPeak` —
/// the breakdown chart's Renderer/Tiler curves are the real per-sample series
/// (nil-compacted), never synthesized from the current scalar ratio.
///
/// L (§3 GPU-L is explicitly "cut" in the mock — no stable public field exists
/// to fill 4×4: no per-core / GPU memory / top-k GPU process on the public
/// layer) consumes the exact same M-tier fields, just given the extra vertical
/// room the board hands it (L is M's width, double its height): a bigger ring,
/// a taller Load chart and more air between rows, instead of literally
/// centring `mediumBody`'s fixed-size ring in empty space.
///
/// Options (`placement.options`, §3.1 GPU Settings): the read side only — the
/// popover UI itself is out of scope here.
///   - `historyWindow` (.number seconds — 30 | 60 | 120, default 60) — the Load
///     chart's trailing window on M/L, mirrors the settings' 30s/60s/120s
///     segmented control. Off-catalog values fall back to 60.
///   - `showLoadBreakdown` (.bool, default true) — the Device/Renderer/Tiler
///     three-line legend, the compute-gap chip and the honest note. Off
///     degrades the Load chart to a solo Device curve (mock: "Optional 缺失降
///     单线") rather than hiding the whole card.
///   - `showSensors` (.bool, default true) — per-card visibility of ALREADY
///     unlocked B-tier readings; this does NOT perform the Pro/helper unlock
///     itself (that flow is global, §5.1) — off just hides the row/capsule on
///     this card even when sensor data is present.
///   - `showRendererFootprint` — deferred/opt-in (`MTLDevice.
///     currentAllocatedSize` self-diagnostics, shown disabled/"即将推出" in
///     both settings variants). No backing data field exists yet, so this
///     widget does not read it.
struct MonitorGPUWidgetView: View {
    let context: MonitorWidgetContext

    init(context: MonitorWidgetContext) {
        self.context = context
    }

    private var system: MonitorSystemSnapshot? { context.snapshot.system }
    private var gpuUsage: Double? { system?.gpuUsage }
    private var cellHeight: CGFloat { context.placement.pixelHeightHint }

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
    // S shows only a load state dot (warm >60 / crit >85). M shows the freshness
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
            .fill(Self.stateDotColor(pct))
            .frame(width: 6, height: 6)
    }

    private var freshnessChip: some View {
        let stale = Self.isStale(sampledAt: system?.gpuSampledAt, now: context.now)
        let color = stale ? MonitorDesign.staleWarm : MonitorDesign.inkFaint
        return HStack(spacing: 4) {
            Circle()
                .strokeBorder(stale ? MonitorDesign.staleWarm : MonitorDesign.signalSteel,
                              lineWidth: 1.5)
                .frame(width: 6, height: 6)
                .opacity(stale ? 0.85 : 0.7)
            // "sampled" / "ago" are words (localized); the age between them is data.
            (Text("sampled") + Text(verbatim: " ")
             + Text(verbatim: Self.freshnessText(sampledAt: system?.gpuSampledAt, now: context.now))
                .foregroundStyle(MonitorDesign.inkMuted)
             + Text(verbatim: " ") + Text("ago"))
                .font(MonitorDesign.labelFont(size: scale.label * 0.96))
        }
        .foregroundStyle(color)
    }

    private var scale: MonitorDesign.TypeScale { .init(cellHeight: cellHeight) }

    // MARK: - S (2×2)

    @ViewBuilder
    private var smallBody: some View {
        if gpuUsage == nil {
            unavailableBody
        } else {
            let pct = gpuUsage ?? 0
            let hasTemp = tempC != nil && showSensorsPreference
            VStack(spacing: 6) {
                ArcGauge(value: pct, peak: peakFraction, lineWidth: 9) {
                    arcCenter(scale: hasTemp ? 0.9 : 1)
                }
                .frame(maxWidth: 150)
                .frame(maxHeight: .infinity)

                peakTag(size: scale.label * 0.9)

                if hasTemp, let t = tempC {
                    temperatureCapsule(t)
                }

                Sparkline(values: history30, domain: 0...1, bandColored: true)
                    .frame(height: max(18, cellHeight * 0.16))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// nil GPU → the honest unavailable state (mock `gpu_s_unavailable`): a dashed
    /// hollow arc, an em-dash where the hero% sits, a "GPU" label, and a caption.
    private var unavailableBody: some View {
        VStack(spacing: 7) {
            ArcGauge(value: nil, lineWidth: 9) {
                VStack(spacing: 1) {
                    Text(verbatim: "—")
                        .font(MonitorDesign.heroFont(size: min(46, max(24, cellHeight * 0.36)) * 1.02))
                        .foregroundStyle(MonitorDesign.naval)
                    Text(verbatim: "GPU")
                        .font(MonitorDesign.labelFont(size: scale.label * 0.94))
                        .tracking(scale.label * 0.14)
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
            }
            .frame(maxWidth: 150)
            .frame(maxHeight: .infinity)

            Text("no sample — utilisation source unavailable")
                .font(MonitorDesign.captionFont(size: scale.caption))
                .foregroundStyle(MonitorDesign.inkFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - M (4×2)

    @ViewBuilder
    private var mediumBody: some View {
        if gpuUsage == nil {
            unavailableBody
        } else {
            VStack(alignment: .leading, spacing: 7) {
                identityRow
                ringAndBreakdown(ringWidth: 96, heroScale: 0.8, peakScale: 0.86, chartMinHeight: 44)
                if showLoadBreakdown {
                    breakdownLegend
                    Text("Device − Renderer gap ≈ compute (Metal / GPU ML) load")
                        .font(MonitorDesign.captionFont(size: scale.caption))
                        .foregroundStyle(MonitorDesign.inkFaint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let row = sensorRow {
                    row
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - L (4×4 cells → M's width, double M's height)
    //
    // Same fields as M (see the type doc's "cut" note) laid out with the extra
    // vertical room: a bigger ring, a taller Load chart, more breathing space
    // between rows, and the honest note allowed to wrap instead of being
    // clipped to one line.

    @ViewBuilder
    private var largeBody: some View {
        if gpuUsage == nil {
            unavailableBody
        } else {
            VStack(alignment: .leading, spacing: 12) {
                identityRow
                ringAndBreakdown(ringWidth: 130, heroScale: 0.92, peakScale: 0.96, chartMinHeight: 90)
                if showLoadBreakdown {
                    breakdownLegend
                    Text("Device − Renderer gap ≈ compute (Metal / GPU ML) load")
                        .font(MonitorDesign.captionFont(size: scale.caption))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
                if let row = sensorRow {
                    row
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// "<gpuDeviceName> · N-core GPU" — mirrors the mock's whispered identity line.
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
        }
    }

    /// Ring + "Load · Ns" chart, shared by M and L — only the ring size, hero/peak
    /// label scale and the chart's height floor differ between the two (mock:
    /// same fields, more room on L). `Renderer`/`Tiler` drop out entirely (a solo
    /// Device curve, no compute chip) when `showLoadBreakdown` is off.
    private func ringAndBreakdown(ringWidth: CGFloat, heroScale: CGFloat, peakScale: CGFloat,
                                   chartMinHeight: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(spacing: 3) {
                ArcGauge(value: gpuUsage ?? 0, peak: peakFraction, lineWidth: 9) {
                    arcCenter(scale: heroScale)
                }
                peakTag(size: scale.label * peakScale)
            }
            .frame(width: ringWidth)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    loadWindowLabel
                    Spacer(minLength: 4)
                    if showLoadBreakdown {
                        computeChip
                    }
                }
                GPUBreakdownChart(
                    device: historyWindowed,
                    renderer: effectiveRendererHistory,
                    tiler: effectiveTilerHistory,
                    reduceMotion: context.reduceMotion
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: chartMinHeight, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// "load · Ns" — the word is the shared "load" catalog key (reused from the
    /// CPU widget's `load` readout, uppercased via `.textCase` to match the
    /// mock's `.klbl` CSS rule); the window length is data (verbatim).
    private var loadWindowLabel: some View {
        (Text("load") + Text(verbatim: " · \(Int(historyWindowSeconds))s"))
            .font(MonitorDesign.labelFont(size: scale.label))
            .tracking(scale.label * 0.12)
            .foregroundStyle(MonitorDesign.inkFaint)
            .textCase(.uppercase)
    }

    /// The compute-gap chip — reads Device − Renderer as an ≈ compute estimate.
    /// Only shown when both Device and Renderer are known (the gap is undefined
    /// otherwise — the mock only renders it in the full-data path).
    @ViewBuilder
    private var computeChip: some View {
        if let compute = Self.computePercent(device: gpuUsage, renderer: system?.gpuRendererUtil) {
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

    /// Device / Renderer / Tiler swatches + live values. A nil util omits that
    /// line and the row compacts (mock: "Optional 缺失降单线").
    private var breakdownLegend: some View {
        HStack(spacing: 14) {
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
            Spacer(minLength: 0)
        }
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
                                  value: "\(Int(t.rounded()))", unit: "°C")
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
                .font(MonitorDesign.heroFont(size: heroSize * factor))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
            Text(verbatim: "%")
                .font(MonitorDesign.labelFont(size: heroSize * factor * 0.5))
                .foregroundStyle(MonitorDesign.inkFaint)
        }
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
    }

    private func temperatureCapsule(_ t: Double) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(MonitorDesign.temperatureColor(t))
                .frame(width: 7, height: 7)
                .shadow(color: MonitorDesign.temperatureColor(t).opacity(0.6), radius: 3)
            (Text(verbatim: "\(Int(t.rounded()))")
             + Text(verbatim: "°C")
                .font(MonitorDesign.labelFont(size: scale.caption * 0.68))
                .foregroundStyle(MonitorDesign.inkFaint))
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
            // Temperature band word (cool/warm/hot), localized then uppercased for
            // display (the case transform is a no-op for non-Latin scripts).
            Text(LocalizedStringKey(Self.tempLabel(t)))
                .font(MonitorDesign.labelFont(size: scale.label * 0.94))
                .tracking(scale.label * 0.12)
                .foregroundStyle(MonitorDesign.inkFaint)
                .textCase(.uppercase)
        }
    }

    // MARK: - Derived values

    private var heroSize: CGFloat { min(46, max(24, cellHeight * 0.36)) }
    private var tempC: Double? { system?.sensors?.gpuTempC }

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
        Self.compactedSeries(context.history.gpuRenderer, times: context.history.gpuSampleTimes,
                              windowSeconds: historyWindowSeconds)
    }

    private var tilerHistory: [Double]? {
        Self.compactedSeries(context.history.gpuTiler, times: context.history.gpuSampleTimes,
                              windowSeconds: historyWindowSeconds)
    }

    /// `nil` (dropping the compute-gap band + line) once `showLoadBreakdown` is
    /// off, even when real Renderer/Tiler samples exist — the setting hides the
    /// breakdown, not just the legend text.
    private var effectiveRendererHistory: [Double]? { showLoadBreakdown ? rendererHistory : nil }
    private var effectiveTilerHistory: [Double]? { showLoadBreakdown ? tilerHistory : nil }

    // MARK: - Settings read side (placement.options, §3.1 GPU Settings)

    private var historyWindowSeconds: Double {
        Self.resolvedHistoryWindowSeconds(context.placement.options["historyWindow"]?.numberValue)
    }

    private var showLoadBreakdown: Bool {
        context.placement.options["showLoadBreakdown"]?.boolValue ?? true
    }

    private var showSensorsPreference: Bool {
        context.placement.options["showSensors"]?.boolValue ?? true
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

// MARK: - Placement sizing hint

private extension MonitorWidgetPlacement {
    /// The container derives its type scale from a cell height. The board owns
    /// the true pixel frame; absent that here, use the SPEC reference cell height
    /// per size so previews and off-board renders pick a sane scale. `large`'s
    /// 2× hint already saturates `TypeScale`'s hero/label/caption clamps at the
    /// same values `medium` reaches — matches the mock (L gets more layout
    /// room, not bigger text) — so no further tuning is needed here.
    var pixelHeightHint: CGFloat {
        switch size {
        case .small: return 150
        case .medium: return 150
        case .large: return 300
        }
    }
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
            .frame(width: 150, height: 150)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .small, gpuUsage: 0.52, withSensors: true))
            .frame(width: 150, height: 150)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .small, gpuUsage: nil))
            .frame(width: 150, height: 150)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("GPU · M") {
    VStack(spacing: 20) {
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .medium, gpuUsage: 0.52))
            .frame(width: 320, height: 150)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .medium, gpuUsage: 0.52, withSensors: true, staleSeconds: 4))
            .frame(width: 320, height: 150)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .medium, gpuUsage: 0.88, staleSeconds: 22))
            .frame(width: 320, height: 150)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .medium, gpuUsage: nil))
            .frame(width: 320, height: 150)
        // showLoadBreakdown = false → solo Device curve, no legend/gap chip/note.
        MonitorGPUWidgetView(context: gpuPreviewContext(
            size: .medium, gpuUsage: 0.52,
            options: ["showLoadBreakdown": .bool(false)]))
            .frame(width: 320, height: 150)
        // showSensors = false with real sensor data present → row stays hidden.
        MonitorGPUWidgetView(context: gpuPreviewContext(
            size: .medium, gpuUsage: 0.52, withSensors: true,
            options: ["showSensors": .bool(false)]))
            .frame(width: 320, height: 150)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("GPU · L") {
    HStack(spacing: 20) {
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .large, gpuUsage: 0.52))
            .frame(width: 320, height: 300)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .large, gpuUsage: 0.52, withSensors: true))
            .frame(width: 320, height: 300)
        // historyWindow = 120s → the settings' longest window on the taller chart.
        MonitorGPUWidgetView(context: gpuPreviewContext(
            size: .large, gpuUsage: 0.68, withSensors: true,
            options: ["historyWindow": .number(120)]))
            .frame(width: 320, height: 300)
        MonitorGPUWidgetView(context: gpuPreviewContext(size: .large, gpuUsage: nil))
            .frame(width: 320, height: 300)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}
#endif
