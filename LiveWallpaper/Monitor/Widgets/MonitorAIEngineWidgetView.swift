import SwiftUI
import LiveWallpaperCore

struct MonitorAIEngineWidgetView: View {
    let context: MonitorWidgetContext

    init(context: MonitorWidgetContext) {
        self.context = context
    }

    var body: some View {
        GeometryReader { geo in
            let rowSpan: CGFloat = context.placement.size == .large ? 2 : 1
            AIEngineContent(context: context, cellHeight: geo.size.height / (2 * rowSpan))
        }
    }
}

private struct AIEngineContent: View {
    /// The tested pure logic lives on the public widget type (see the extension
    /// at the bottom); the view body only ever calls through this alias.
    private typealias Widget = MonitorAIEngineWidgetView

    let context: MonitorWidgetContext
    let cellHeight: CGFloat

    private var system: MonitorSystemSnapshot? { context.snapshot.system }
    private var scale: MonitorDesign.TypeScale { .init(cellHeight: cellHeight) }

    /// The honest tri-state.
    private var state: Widget.DisplayState { Widget.displayState(aneActive: system?.aneActive) }
    /// A-tier: whether the Neural Engine is in use (any non-zero footprint).
    private var aneActive: Bool { state == .active }
    /// A-tier: the top-k consumers by footprint (non-nil ⇔ active).
    private var processes: [MonitorANEProcess]? { system?.aneProcesses }
    /// B-tier instantaneous ANE power (W); present only with the Pro helper.
    private var aneWatts: Double? { system?.sensors?.aneWatts }
    private var hasB: Bool { aneWatts != nil }

    var body: some View {
        MonitorWidgetContainer(
            label: "AI ENGINE",
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

    @ViewBuilder
    private var statusAccessory: some View {
        if state == .unsampled {
            Text(verbatim: "n/a")
                .tracking(0.5)
                .foregroundStyle(MonitorDesign.inkFaint)
        } else {
            HStack(spacing: 6) {
                if let right = headerRightLabel {
                    Text(verbatim: right)
                        .font(MonitorDesign.labelFont(size: scale.label))
                        .foregroundStyle(MonitorDesign.inkMuted)
                }
                if aneActive {
                    BreathingDot(color: MonitorDesign.signalAmber, size: 6)
                }
            }
        }
    }

    private var headerRightLabel: String? {
        switch context.placement.size {
        case .small:  return hasB ? "ANE" : nil
        case .medium: return "ri_neural_footprint"
        case .large:  return "ri_neural_footprint"
        }
    }

    // MARK: - S (170×170 — content ≈ 138×125)

    @ViewBuilder
    private var smallBody: some View {
        switch state {
        case .unsampled:
            unavailableBody
        case .idle, .active:
            if hasB, let watts = aneWatts {
                smallPowerBody(watts: watts)
            } else {
                smallActivityBody
            }
        }
    }

    private var smallActivityBody: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 0)
            activityIndicator(heroFactor: 0.72)
            topApp
            Text(verbatim: "ri_neural_footprint · no util%")
                .font(MonitorDesign.captionFont(size: scale.caption * 0.92))
                .tracking(scale.caption * 0.05)
                .foregroundStyle(MonitorDesign.inkFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monitorChip(scale)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func smallPowerBody(watts: Double) -> some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            ArcGauge(value: Widget.powerFraction(watts), color: MonitorDesign.loadBandColor(Widget.powerFraction(watts)), lineWidth: 9) {
                powerHub(watts: watts, heroFactor: 0.86)
            }
            .frame(maxWidth: 150)
            .frame(maxHeight: .infinity)
            topApp
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// nil processes (sampling off) → the honest unavailable state: a calm neural
    /// dot, an "AI ENGINE" tag, and a caption. Never a 0%/idle claim.
    private var unavailableBody: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Circle()
                    .fill(MonitorDesign.signalIdle.opacity(0.6))
                    .frame(width: 9, height: 9)
                Text(verbatim: "AI ENGINE")
                    .font(MonitorDesign.heroFont(size: scale.hero * 0.5))
                    .tracking(scale.label * 0.12)
                    .foregroundStyle(MonitorDesign.inkMuted)
            }
            Text("no ANE sample")
                .font(MonitorDesign.captionFont(size: scale.caption))
                .foregroundStyle(MonitorDesign.inkFaint)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - M (364×170 — content ≈ 332×125)

    @ViewBuilder
    private var mediumBody: some View {
        switch state {
        case .unsampled:
            unavailableBody
        case .idle, .active:
            if hasB, let watts = aneWatts {
                mediumPowerBody(watts: watts)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    mediumActivityHeader
                    listOrIdle
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var mediumActivityHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            activityIndicator(heroFactor: 0.5)
                .monitorChip(scale)
            Spacer(minLength: 6)
            topApp
        }
    }

    private func mediumPowerBody(watts: Double) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ArcGauge(value: Widget.powerFraction(watts), color: MonitorDesign.loadBandColor(Widget.powerFraction(watts)), lineWidth: 9) {
                powerHub(watts: watts, heroFactor: 0.72)
            }
            .frame(width: 96)

            VStack(alignment: .leading, spacing: 4) {
                if let dram = dramLine {
                    dram
                }
                if !aneActive {
                    // Idle: the list is gone, so the A-tier state word ("no ANE
                    // activity") must surface here instead of a list row.
                    topApp
                }
                listOrIdle
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The ranked-list slot both tiers share: the honest per-process list when
    /// active, the quiet idle caption otherwise.
    @ViewBuilder
    private var listOrIdle: some View {
        if let list = processes {
            processList(Widget.rankedProcesses(list))
        } else {
            idlePlaceholder
        }
    }

    // MARK: - L (364×376 — content ≈ 332×331)

    @ViewBuilder
    private var largeBody: some View {
        switch state {
        case .unsampled:
            unavailableBody
        case .idle, .active:
            VStack(alignment: .leading, spacing: scale.caption * 0.7) {
                if hasB, let watts = aneWatts {
                    largePowerHeader(watts: watts)
                } else {
                    largeActivityHeader
                }
                if let list = processes {
                    Rectangle()
                        .fill(MonitorDesign.hairline)
                        .frame(height: MonitorDesign.hairlineWidth)
                        .opacity(0.7)
                    processList(
                        Widget.rankedProcesses(list),
                        rowGap: scale.caption * 1.3,
                        barHeight: scale.caption * 0.52
                    )
                }
                Spacer(minLength: 0)
                honestFooter
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var largeActivityHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            activityIndicator(heroFactor: 0.62)
                .monitorChip(scale)
            Spacer(minLength: 8)
            topApp
        }
    }

    /// L A+B header: the shared power arc + hub beside a stacked column carrying the activity state (which M-B omits) and the DRAM bandwidth line.
    private func largePowerHeader(watts: Double) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ArcGauge(value: Widget.powerFraction(watts), color: MonitorDesign.loadBandColor(Widget.powerFraction(watts)), lineWidth: 9) {
                powerHub(watts: watts, heroFactor: 0.78)
            }
            .frame(width: 104)

            VStack(alignment: .leading, spacing: 8) {
                activityIndicator(heroFactor: 0.4)
                    .monitorChip(scale)
                if let dram = dramLine {
                    dram
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Shows an explicit idle state when ANE sampling succeeds without active processes.
    private var idlePlaceholder: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(verbatim: "ri_neural_footprint · no util%")
                .font(MonitorDesign.captionFont(size: scale.caption * 0.92))
                .tracking(scale.caption * 0.05)
                .foregroundStyle(MonitorDesign.inkFaint)
                .monitorChip(scale)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The on-card honest boundary (L only): a neural swatch + the same technical caption S uses, with the "helper" tag when B is present.
    private var honestFooter: some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(MonitorDesign.neuralDim)
                    .frame(width: scale.caption * 0.5, height: scale.caption * 0.5)
                    .opacity(0.8)
                Text(verbatim: "ri_neural_footprint · no util%")
                    .font(MonitorDesign.captionFont(size: scale.caption * 0.9))
                    .foregroundStyle(MonitorDesign.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .monitorChip(scale)
            Spacer(minLength: 0)
            if hasB {
                Text("helper")
                    .font(MonitorDesign.labelFont(size: scale.label * 0.9))
                    .tracking(scale.label * 0.1)
                    .foregroundStyle(MonitorDesign.inkFaint.opacity(0.7))
                    .monitorChip(scale)
            }
        }
    }

    // MARK: - Shared pieces

    private func activityIndicator(heroFactor: CGFloat) -> some View {
        HStack(spacing: scale.hero * heroFactor * 0.28) {
            BreathingDot(
                color: aneActive ? MonitorDesign.neural : MonitorDesign.signalIdle,
                size: scale.hero * heroFactor * 0.42,
                animated: aneActive
            )
            Text(aneActive ? LocalizedStringKey("ACTIVE") : LocalizedStringKey("IDLE"))
                .font(MonitorDesign.heroFont(size: scale.hero * heroFactor))
                .tracking(scale.hero * heroFactor * 0.02)
                .foregroundStyle(aneActive ? MonitorDesign.neuralInk : MonitorDesign.inkMuted)
        }
    }

    @ViewBuilder
    private var topApp: some View {
        Group {
            if aneActive, let busiest = Widget.busiestProcess(processes ?? []) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: busiest.name)
                        .font(MonitorDesign.subFont(size: scale.caption))
                        .foregroundStyle(MonitorDesign.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: "·")
                        .font(MonitorDesign.captionFont(size: scale.caption))
                        .foregroundStyle(MonitorDesign.inkFaint)
                    footprintValue(busiest.footprintBytes, size: scale.caption)
                }
            } else {
                Text("no ANE activity")
                    .font(MonitorDesign.captionFont(size: scale.caption))
                    .foregroundStyle(MonitorDesign.inkFaint)
            }
        }
        .monitorChip(scale)
    }

    private func footprintValue(_ bytes: UInt64, size: CGFloat) -> some View {
        let parts = Widget.splitBytes(bytes)
        return (Text(verbatim: parts.value)
            + Text(verbatim: parts.unit)
                .font(MonitorDesign.labelFont(size: size * 0.7))
                .foregroundStyle(MonitorDesign.inkFaint))
            .font(MonitorDesign.subFont(size: size))
            .monospacedDigit()
            .foregroundStyle(MonitorDesign.neuralValue)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func powerHub(watts: Double, heroFactor: CGFloat) -> some View {
        let size = scale.hero * heroFactor
        return (Text(verbatim: String(format: "%.1f", max(0, watts)))
            + Text(verbatim: "W")
                .font(MonitorDesign.subFont(size: size * 0.5))
                .foregroundStyle(MonitorDesign.inkMuted))
            .font(MonitorDesign.heroFont(size: size))
            .monospacedDigit()
            .foregroundStyle(MonitorDesign.inkPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private var dramLine: (some View)? {
        let r = system?.sensors?.dramReadBytesPerSec
        let w = system?.sensors?.dramWriteBytesPerSec
        guard r != nil || w != nil else { return Optional<AnyView>.none }
        return AnyView(
            HStack(spacing: 8) {
                Text(verbatim: "DRAM")
                    .font(MonitorDesign.labelFont(size: scale.label * 0.94))
                    .tracking(scale.label * 0.1)
                    .foregroundStyle(MonitorDesign.inkFaint)
                if let r {
                    dramReading(tag: "R", rate: r)
                }
                if r != nil && w != nil {
                    Text(verbatim: "·").foregroundStyle(MonitorDesign.inkFaint.opacity(0.5))
                }
                if let w {
                    dramReading(tag: "W", rate: w)
                }
                Spacer(minLength: 0)
                Text("helper")
                    .font(MonitorDesign.labelFont(size: scale.label * 0.9))
                    .tracking(scale.label * 0.1)
                    .foregroundStyle(MonitorDesign.inkFaint.opacity(0.7))
                    .monitorChip(scale)
            }
        )
    }

    private func dramReading(tag: String, rate: Double) -> some View {
        let parts = Widget.splitRate(rate)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: tag)
                .font(.system(size: scale.caption * 0.86, weight: .bold, design: .rounded))
                .foregroundStyle(MonitorDesign.signalSteel)
            (Text(verbatim: parts.value)
             + Text(verbatim: parts.unit)
                .font(MonitorDesign.labelFont(size: scale.caption * 0.7))
                .foregroundStyle(MonitorDesign.inkFaint))
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func processList(_ list: [MonitorANEProcess], rowGap: CGFloat? = nil, barHeight: CGFloat? = nil) -> some View {
        let top = list.first?.footprintBytes ?? 1
        return VStack(alignment: .leading, spacing: rowGap ?? scale.caption * 0.34) {
            HStack(spacing: 10) {
                Text(verbatim: "PROGRAM")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "ANE MEM")
                    .frame(width: memColumnWidth, alignment: .trailing)
            }
            .font(MonitorDesign.labelFont(size: scale.label * 0.98))
            .tracking(scale.label * 0.08)
            .foregroundStyle(MonitorDesign.inkFaint)

            ForEach(Array(list.enumerated()), id: \.offset) { _, proc in
                processRow(proc, topFootprint: top, barHeight: barHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func processRow(_ proc: MonitorANEProcess, topFootprint: UInt64, barHeight: CGFloat? = nil) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(MonitorDesign.neuralDim)
                    .frame(width: scale.caption * 0.5, height: scale.caption * 0.5)
                    .opacity(0.85)
                Text(verbatim: proc.name)
                    .font(.system(size: scale.caption, weight: .medium, design: .rounded))
                    .foregroundStyle(MonitorDesign.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ANEBar(fraction: Widget.barFraction(proc.footprintBytes, top: topFootprint))
                    .frame(maxWidth: .infinity)
                    .frame(height: barHeight ?? scale.caption * 0.42)
                footprintValue(proc.footprintBytes, size: scale.caption * 0.94)
                    .frame(width: memValueWidth, alignment: .trailing)
            }
            .frame(width: memColumnWidth)
        }
    }

    // MARK: - Layout metrics

    private var memColumnWidth: CGFloat { context.placement.size == .large ? 120 : 96 }
    private var memValueWidth: CGFloat { 46 }
}

// MARK: - Pure logic (tested)

extension MonitorAIEngineWidgetView {

    /// The honest render state, derived from the producer's `aneActive` tri-state: `nil` = the ANE walk hasn't run (sampling off) → the quiet unsampled state; `false` = sampled, no footprint (idle); `true` = active.
    enum DisplayState: Equatable { case unsampled, idle, active }

    nonisolated static func displayState(aneActive: Bool?) -> DisplayState {
        switch aneActive {
        case .none: return .unsampled
        case .some(false): return .idle
        case .some(true): return .active
        }
    }

    nonisolated static let powerCeilingWatts: Double = 8

    /// ANE power as a fraction of the ceiling for the shared arc (clamped 0…1).
    nonisolated static func powerFraction(_ watts: Double) -> Double {
        guard watts.isFinite else { return 0 }
        return min(1, max(0, watts / powerCeilingWatts))
    }

    /// The busiest ANE consumer = the process with the largest footprint. nil for
    /// an empty list. Ties resolve to the first max encountered (stable).
    nonisolated static func busiestProcess(_ list: [MonitorANEProcess]) -> MonitorANEProcess? {
        list.max { $0.footprintBytes < $1.footprintBytes }
    }

    /// Top-k processes ranked by footprint (desc), capped at 5 — the honest per-process layer.
    nonisolated static func rankedProcesses(_ list: [MonitorANEProcess]) -> [MonitorANEProcess] {
        Array(list.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(5))
    }

    /// Bar length = this process's footprint ÷ the top (max) footprint, 0…1. The
    /// top row is always full; a zero top yields an empty bar (never a divide-by-0).
    nonisolated static func barFraction(_ footprint: UInt64, top: UInt64) -> Double {
        guard top > 0 else { return 0 }
        return min(1, max(0, Double(footprint) / Double(top)))
    }

    /// Footprint split into value + unit strings via the shared `MonitorFormat.bytes`
    /// port (so "762 MB" matches the design's rounding). Returns (" 762", " MB").
    nonisolated static func splitBytes(_ bytes: UInt64) -> (value: String, unit: String) {
        splitFormatted(MonitorFormat.bytes(bytes))
    }

    nonisolated static func splitRate(_ bytesPerSec: Double) -> (value: String, unit: String) {
        splitFormatted(MonitorFormat.rate(bytesPerSec))
    }

    /// Split a "<number> <unit>" formatted string at its first space so the unit
    /// can be de-emphasised. Falls back to the whole string as the value.
    nonisolated static func splitFormatted(_ text: String) -> (value: String, unit: String) {
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[space...]))
    }
}

// MARK: - Process footprint bar

private struct ANEBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clamped = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(MonitorDesign.track2)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                    )
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [MonitorDesign.oklch(0.54, 0.06, 300), MonitorDesign.neural],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, w * CGFloat(clamped)))
            }
        }
    }
}

// MARK: - AI Engine palette
private extension MonitorDesign {
    /// `--neural` — the ACTIVE dot + bar terminus.
    static let neural = oklch(0.72, 0.11, 300)
    /// `--neural-dim` — the process-row swatch.
    static let neuralDim = oklch(0.60, 0.07, 300)
    static let neuralInk = oklch(0.90, 0.06, 300)
    static let neuralValue = oklch(0.85, 0.055, 300)
}

// MARK: - Previews

#if DEBUG
private func aiEnginePreviewContext(
    size: MonitorWidgetSize,
    active: Bool? = true,
    processes: [MonitorANEProcess]? = defaultANEProcesses(),
    watts: Double? = nil,
    dram: (r: Double, w: Double)? = nil
) -> MonitorWidgetContext {
    var sys = MonitorSystemSnapshot()
    sys.aneActive = active
    sys.aneProcesses = processes
    if watts != nil || dram != nil {
        var sensors = MonitorSensorReadings()
        sensors.aneWatts = watts
        sensors.dramReadBytesPerSec = dram?.r
        sensors.dramWriteBytesPerSec = dram?.w
        sys.sensors = sensors
    }

    var snapshot = MonitorSnapshot()
    snapshot.timestamp = Date().timeIntervalSince1970
    snapshot.system = sys

    return MonitorWidgetContext(
        snapshot: snapshot,
        history: MonitorHistorySnapshot(),
        placement: MonitorWidgetPlacement(kind: .aiEngine, size: size),
        isEditing: false,
        reduceMotion: false,
        now: Date()
    )
}

private func defaultANEProcesses() -> [MonitorANEProcess] {
    let mb = 1_048_576.0
    return [
        MonitorANEProcess(name: "WhisperKit", footprintBytes: UInt64(762 * mb)),
        MonitorANEProcess(name: "Xcode", footprintBytes: UInt64(120 * mb)),
        MonitorANEProcess(name: "Claude", footprintBytes: UInt64(88 * mb)),
        MonitorANEProcess(name: "Photos", footprintBytes: UInt64(54 * mb)),
        MonitorANEProcess(name: "Spotlight", footprintBytes: UInt64(31 * mb)),
    ]
}

private let dramSample = (r: 41.3 * 1_073_741_824.0, w: 18.7 * 1_073_741_824.0)

#Preview("AI Engine · S") {
    HStack(spacing: 20) {
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(size: .small))
            .frame(width: 170, height: 170)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .small, active: false, processes: nil))
            .frame(width: 170, height: 170)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .small, active: nil, processes: nil))
            .frame(width: 170, height: 170)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(size: .small, watts: 3.2))
            .frame(width: 170, height: 170)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("AI Engine · M") {
    VStack(spacing: 20) {
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(size: .medium))
            .frame(width: 364, height: 170)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .medium, active: false, processes: nil))
            .frame(width: 364, height: 170)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .medium, watts: 3.2, dram: dramSample))
            .frame(width: 364, height: 170)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .medium, active: false, processes: nil, watts: 0.4, dram: dramSample))
            .frame(width: 364, height: 170)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .medium, active: nil, processes: nil))
            .frame(width: 364, height: 170)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("AI Engine · L") {
    HStack(alignment: .top, spacing: 20) {
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(size: .large))
            .frame(width: 364, height: 376)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .large, watts: 3.2, dram: dramSample))
            .frame(width: 364, height: 376)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .large, active: false, processes: nil))
            .frame(width: 364, height: 376)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}
#endif
