import LiveWallpaperCore
import SwiftUI

/// Per-widget settings popover shown from the inspector's instrument list.
///
/// Native chrome (standard AppKit/SwiftUI controls — SPEC §5.0-a) rather than
/// the board's own matte instrument styling. Every kind gets a size picker (only
/// the sizes `kind.allowedSizes` permits) and a remove button; kinds with tuning
/// add their own controls:
///   • Processes — a row-count stepper (1…12, default 5), key `count` (.number).
///   • CPU/GPU/Memory/Disk — a `historyWindow` trend picker plus each kind's
///     toggles (`showHeatmap`/`showComposition`/`showSensors`,
///     `showLoadBreakdown`, `showTopProcesses`) and the Memory/Disk `breakdown`.
///   • Usage/Fleet — a `provider` filter, plus Usage's `primaryMetric` and
///     Fleet's `fleetSort` / `fleetMaxRows`.
///
/// Writes follow one rule: a value equal to the widget's default drops the key
/// so `options` stays minimal.
///
/// Edits are applied through `onUpdate`, which the inspector persists via
/// `ScreenManager`. `MonitorWidgetDraft` holds the pure option encode/decode so
/// the round-trips are unit-testable without any view.
struct MonitorWidgetSettingsPopover: View {
    /// One fixed width for every surface that hosts this popover (inspector
    /// popover, board settings card) — segmented pickers need the room, and the
    /// board card's deterministic placement needs the number up front.
    static let preferredWidth: CGFloat = 360

    let placement: MonitorWidgetPlacement
    let onUpdate: (MonitorWidgetPlacement) -> Void
    let onRemove: () -> Void

    var body: some View {
        // Flat, single-surface layout (macOS Settings detail pane): the popover's
        // own material is the only background — no nested cards — so groups read as
        // clean sections separated by spacing + one divider, not stacked panes.
        VStack(alignment: .leading, spacing: 18) {
            header

            if placement.kind.allowedSizes.count > 1 {
                sizePicker
            }

            if hasKindOptions {
                kindOptions
            }

            Divider()
            removeButton
        }
        .padding(20)
        .frame(width: Self.preferredWidth)
    }

    /// Apple-style header: the instrument's glyph in a Liquid-Glass chip, its name,
    /// and a quiet subtitle so the popover reads like a Settings detail pane.
    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: MonitorWidgetFactory.icon(placement.kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .adaptiveGlassSurface(.roundedRectangle(10))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: MonitorWidgetFactory.displayName(placement.kind))
                    .font(.headline)
                Text("Instrument settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Destructive footer as its own row so it reads distinct from the tuning.
    private var removeButton: some View {
        Button(role: .destructive) {
            onRemove()
        } label: {
            Label("Remove Instrument", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderless)
        .tint(.red)
    }

    /// Whether the current kind contributes a tuning section (drives whether the
    /// options card is drawn at all — no empty glass card for optionless kinds).
    private var hasKindOptions: Bool {
        switch placement.kind {
        case .processes, .cpu, .gpu, .memory, .disk, .usage, .fleet: return true
        default: return false
        }
    }

    // MARK: - Size

    @ViewBuilder
    private var sizePicker: some View {
        let allowed = placement.kind.allowedSizes
        if allowed.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Size")
                    .font(.subheadline.weight(.medium))
                Picker("", selection: Binding(
                    get: { placement.size },
                    set: { newSize in
                        var next = placement
                        next.size = newSize
                        onUpdate(next)
                    }
                )) {
                    ForEach(allowed, id: \.self) { size in
                        Text(verbatim: Self.sizeLabel(size)).tag(size)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("Widget size"))
            }
        }
    }

    // MARK: - Kind-specific options

    @ViewBuilder
    private var kindOptions: some View {
        switch placement.kind {
        case .processes:
            processesOptions
        case .cpu:
            cpuOptions
        case .gpu:
            gpuOptions
        case .memory:
            memoryOptions
        case .disk:
            diskOptions
        case .usage:
            usageOptions
        case .fleet:
            fleetOptions
        default:
            EmptyView()
        }
    }

    // MARK: Processes

    private var processesOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Stepper(
                value: Binding(
                    get: { MonitorWidgetDraft.processCount(placement) },
                    set: { onUpdate(MonitorWidgetDraft.settingProcessCount($0, on: placement)) }
                ),
                in: MonitorWidgetDraft.processCountRange
            ) {
                HStack {
                    Text("Rows")
                    Spacer()
                    Text(verbatim: "\(MonitorWidgetDraft.processCount(placement))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: CPU

    private var cpuOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            historyWindowPicker(defaultWindow: MonitorCPUDraft.defaultHistoryWindow(for: placement.size))
            VStack(spacing: 8) {
                toggleRow("Show heatmap", isOn: boolBinding(key: MonitorCPUDraft.showHeatmapKey, default: true))
                toggleRow("Show composition", isOn: boolBinding(key: MonitorCPUDraft.showCompositionKey, default: true))
                toggleRow("Show sensors", isOn: boolBinding(key: MonitorCPUDraft.showSensorsKey, default: true))
                if placement.size == .small {
                    toggleRow("Show history curve", isOn: boolBinding(key: MonitorWidgetDraft.showTrendKey, default: true))
                }
            }
        }
    }

    // MARK: GPU

    private var gpuOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            historyWindowPicker(defaultWindow: 60)
            gpuSamplingPicker
            VStack(spacing: 8) {
                toggleRow("Show load breakdown", isOn: boolBinding(key: MonitorWidgetDraft.showLoadBreakdownKey, default: true))
                toggleRow("Show sensors", isOn: boolBinding(key: MonitorWidgetDraft.showSensorsKey, default: true))
                if placement.size == .small {
                    toggleRow("Show history curve", isOn: boolBinding(key: MonitorWidgetDraft.showTrendKey, default: true))
                }
            }
        }
    }

    /// GPU sampling period — the IOAccelerator walk's cadence. Default 6s.
    private var gpuSamplingPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sampling interval")
                .font(.subheadline.weight(.medium))
            Picker("", selection: Binding(
                get: { MonitorWidgetDraft.gpuSampleSeconds(placement) ?? 6 },
                set: { onUpdate(MonitorWidgetDraft.settingGPUSampleSeconds($0, on: placement)) }
            )) {
                ForEach(MonitorWidgetDraft.gpuSampleChoices, id: \.self) { seconds in
                    Text(verbatim: "\(Int(seconds))s").tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("GPU sampling interval"))
        }
    }

    // MARK: Memory

    private var memoryOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            historyWindowPicker(defaultWindow: placement.size == .large ? 120 : 60)
            breakdownPicker
            VStack(alignment: .leading, spacing: 4) {
                toggleRow("Show top processes", isOn: boolBinding(key: MonitorWidgetDraft.showTopProcessesKey, default: true))
                if placement.size != .large {
                    Text("Top processes show on the large size only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Disk

    private var diskOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            historyWindowPicker(defaultWindow: 120)
            breakdownPicker
            VStack(alignment: .leading, spacing: 4) {
                toggleRow("Show top processes", isOn: boolBinding(key: MonitorWidgetDraft.showTopProcessesKey, default: true))
                if placement.size != .large {
                    Text("Top processes show on the large size only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Usage

    private var usageOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerPicker(key: MonitorWidgetDraft.usageProviderKey)
            primaryMetricPicker
        }
    }

    // MARK: Fleet

    private var fleetOptions: some View {
        let fallback = placement.size == .large ? 6 : 3
        return VStack(alignment: .leading, spacing: 14) {
            providerPicker(key: MonitorFleetWidgetView.Option.provider)

            Picker(selection: Binding(
                get: { MonitorFleetWidgetView.sortMode(placement.options) },
                set: { onUpdate(MonitorWidgetDraft.settingFleetSort($0, on: placement)) }
            )) {
                Text("Attention").tag(MonitorFleetWidgetView.SortMode.attention)
                Text("Recent").tag(MonitorFleetWidgetView.SortMode.recent)
                Text("Cost").tag(MonitorFleetWidgetView.SortMode.cost)
            } label: {
                Text("Sort")
            }
            .controlSize(.small)

            Stepper(
                value: Binding(
                    get: { MonitorFleetWidgetView.rowCap(placement.options, fallback: fallback) },
                    set: { onUpdate(MonitorWidgetDraft.settingFleetMaxRows($0, fallback: fallback, on: placement)) }
                ),
                in: 1...fallback
            ) {
                HStack {
                    Text("Rows")
                    Spacer()
                    Text(verbatim: "\(MonitorFleetWidgetView.rowCap(placement.options, fallback: fallback))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: Shared controls

    /// Segmented history-window control shared by CPU/GPU/Memory/Disk. Always
    /// 30/60/120s — no "Auto": when the option is unset the segment matching the
    /// widget's own `defaultWindow` is highlighted, and picking that value again
    /// drops the key (so it stays on the default across resizes).
    @ViewBuilder
    private func historyWindowPicker(defaultWindow: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History window")
                .font(.subheadline.weight(.medium))
            Picker("", selection: Binding(
                get: { MonitorWidgetDraft.historyWindowTag(placement, clearValue: defaultWindow) },
                set: { onUpdate(MonitorWidgetDraft.settingHistoryWindow(tag: $0, clearValue: defaultWindow, on: placement)) }
            )) {
                Text(verbatim: "30s").tag(30)
                Text(verbatim: "60s").tag(60)
                Text(verbatim: "120s").tag(120)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("History window"))
        }
    }

    /// Full/Compact breakdown detail control shared by Memory/Disk.
    private var breakdownPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Breakdown")
                .font(.subheadline.weight(.medium))
            Picker("", selection: Binding(
                get: { MonitorWidgetDraft.breakdownCompact(placement) },
                set: { onUpdate(MonitorWidgetDraft.settingBreakdownCompact($0, on: placement)) }
            )) {
                Text("Full").tag(false)
                Text("Compact").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("Breakdown"))
        }
    }

    /// All/Claude/Codex provider filter shared by Usage/Fleet (they persist the
    /// same "all"/"claude"/"codex" values under different keys). Brand names are
    /// verbatim; only the "All" segment is localized.
    private func providerPicker(key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Provider")
                .font(.subheadline.weight(.medium))
            Picker("", selection: Binding(
                get: { MonitorWidgetDraft.providerTag(placement, key: key) },
                set: { onUpdate(MonitorWidgetDraft.settingProvider($0, key: key, on: placement)) }
            )) {
                Text("All").tag("all")
                Text(verbatim: "Claude").tag("claude")
                Text(verbatim: "Codex").tag("codex")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("Provider"))
        }
    }

    /// Usage's Tokens/Cost primary-metric control.
    private var primaryMetricPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Primary metric")
                .font(.subheadline.weight(.medium))
            Picker("", selection: Binding(
                get: { MonitorWidgetDraft.usageCostPrimary(placement) },
                set: { onUpdate(MonitorWidgetDraft.settingUsageCostPrimary($0, on: placement)) }
            )) {
                Text("Tokens").tag(false)
                Text("Cost").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("Primary metric"))
        }
    }

    /// Bool toggle binding with the shared "drop the key when it equals the
    /// default" discipline, so an untouched (or reset-to-default) widget carries
    /// no option at all.
    private func boolBinding(key: String, default def: Bool) -> Binding<Bool> {
        Binding(
            get: { placement.options[key]?.boolValue ?? def },
            set: { onUpdate(MonitorWidgetDraft.settingBool($0, key: key, default: def, on: placement)) }
        )
    }

    /// A clean full-width switch row: label pinned left, switch pinned to the
    /// trailing edge (macOS Settings style) instead of the two clustered together.
    private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - Labels

    static func sizeLabel(_ size: MonitorWidgetSize) -> String {
        switch size {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

}

// MARK: - Pure draft mutations (unit-tested)

/// Pure encode/decode of a placement's option bag for the settings popover. Kept
/// free of any view type so the round-trips are unit-testable. Each mutator
/// returns a NEW placement with the option written under the key the widget
/// reads (verified against `MonitorProcessesWidgetView`).
enum MonitorWidgetDraft {
    static let countKey = "count"

    static let processCountRange = 1...12
    static let defaultProcessCount = 5

    // MARK: GPU · sampling period

    static let gpuSampleSecondsKey = "gpuSampleSeconds"
    static let gpuSampleChoices: [Double] = [2, 6, 10]

    static func gpuSampleSeconds(_ placement: MonitorWidgetPlacement) -> Double? {
        guard let raw = placement.options[gpuSampleSecondsKey]?.numberValue else { return nil }
        return gpuSampleChoices.contains(raw) ? raw : nil
    }

    /// Default GPU sampling period (seconds) when a GPU widget doesn't override it.
    static let gpuDefaultSeconds: Double = 6

    /// Board-level read for the runtime lease: the fastest period any GPU
    /// placement requests. A GPU widget at its default counts as `gpuDefaultSeconds`
    /// (NOT nil), so the cross-lease MIN can't let another screen's slower explicit
    /// choice override a default screen's faster cadence. nil only when NO GPU
    /// widget is placed.
    static func gpuSampleSeconds(in widgets: [MonitorWidgetPlacement]) -> Double? {
        widgets.filter { $0.kind == .gpu }
            .map { gpuSampleSeconds($0) ?? gpuDefaultSeconds }
            .min()
    }

    static func settingGPUSampleSeconds(
        _ value: Double, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if value == 6 || !gpuSampleChoices.contains(value) {
            next.options.removeValue(forKey: gpuSampleSecondsKey)   // default drops the key
        } else {
            next.options[gpuSampleSecondsKey] = .number(value)
        }
        return next
    }

    // MARK: Processes · count

    static func processCount(_ placement: MonitorWidgetPlacement) -> Int {
        guard let raw = placement.options[countKey]?.numberValue else { return defaultProcessCount }
        return min(max(Int(raw), processCountRange.lowerBound), processCountRange.upperBound)
    }

    static func settingProcessCount(
        _ value: Int, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        let clamped = min(max(value, processCountRange.lowerBound), processCountRange.upperBound)
        var next = placement
        next.options[countKey] = .number(Double(clamped))
        return next
    }

    // MARK: Shared option keys
    //
    // These mirror the literal keys the widgets read (`MonitorCPUWidgetView`,
    // `MonitorGPUWidgetView`, `MonitorMemoryWidgetView`, `MonitorDiskWidgetView`,
    // `MonitorUsageWidgetView`). Fleet keys reuse `MonitorFleetWidgetView.Option`.
    // Every write follows one rule: a value equal to the widget's default DROPS
    // the key (so `options` stays minimal), otherwise it is written explicitly.
    static let historyWindowKey = "historyWindow"
    static let showLoadBreakdownKey = "showLoadBreakdown"
    static let showSensorsKey = "showSensors"
    static let showTopProcessesKey = "showTopProcesses"
    /// CPU/GPU S-size history sparkline visibility (default true).
    static let showTrendKey = "showTrend"
    static let breakdownKey = "breakdown"
    static let usageProviderKey = "provider"
    static let primaryMetricKey = "primaryMetric"

    static let historyWindowChoices = [30, 60, 120]

    // MARK: History window (CPU/GPU/Memory/Disk)

    /// Segment tag to highlight: an in-catalog persisted value, else `clearValue`
    /// (the tag standing in for "unset" — Auto for size-defaulting kinds, or the
    /// fixed default for the others).
    static func historyWindowTag(_ placement: MonitorWidgetPlacement, clearValue: Int) -> Int {
        guard let raw = placement.options[historyWindowKey]?.numberValue else { return clearValue }
        let value = Int(raw)
        return historyWindowChoices.contains(value) ? value : clearValue
    }

    static func settingHistoryWindow(
        tag: Int, clearValue: Int, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if tag == clearValue || !historyWindowChoices.contains(tag) {
            next.options.removeValue(forKey: historyWindowKey)
        } else {
            next.options[historyWindowKey] = .number(Double(tag))
        }
        return next
    }

    // MARK: Breakdown (Memory/Disk)

    static func breakdownCompact(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[breakdownKey]?.stringValue == "compact"
    }

    static func settingBreakdownCompact(
        _ compact: Bool, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if compact {
            next.options[breakdownKey] = .string("compact")
        } else {
            next.options.removeValue(forKey: breakdownKey)
        }
        return next
    }

    // MARK: Provider filter (Usage/Fleet)

    /// "all" / "claude" / "codex" — anything else (or unset) reads as "all".
    static func providerTag(_ placement: MonitorWidgetPlacement, key: String) -> String {
        switch placement.options[key]?.stringValue {
        case "claude": return "claude"
        case "codex": return "codex"
        default: return "all"
        }
    }

    static func settingProvider(
        _ tag: String, key: String, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if tag == "claude" || tag == "codex" {
            next.options[key] = .string(tag)
        } else {
            next.options.removeValue(forKey: key)
        }
        return next
    }

    // MARK: Primary metric (Usage)

    static func usageCostPrimary(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[primaryMetricKey]?.stringValue == "cost"
    }

    static func settingUsageCostPrimary(
        _ costPrimary: Bool, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if costPrimary {
            next.options[primaryMetricKey] = .string("cost")
        } else {
            next.options.removeValue(forKey: primaryMetricKey)
        }
        return next
    }

    // MARK: Fleet sort + row cap

    static func settingFleetSort(
        _ mode: MonitorFleetWidgetView.SortMode, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if mode == .attention {
            next.options.removeValue(forKey: MonitorFleetWidgetView.Option.sort)
        } else {
            next.options[MonitorFleetWidgetView.Option.sort] = .string(mode.rawValue)
        }
        return next
    }

    /// The per-size max (`fallback`) is the default, so pinning to it drops the
    /// key and keeps the widget on "auto max" across future resizes.
    static func settingFleetMaxRows(
        _ value: Int, fallback: Int, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        let clamped = min(max(value, 1), fallback)
        var next = placement
        if clamped >= fallback {
            next.options.removeValue(forKey: MonitorFleetWidgetView.Option.maxRows)
        } else {
            next.options[MonitorFleetWidgetView.Option.maxRows] = .number(Double(clamped))
        }
        return next
    }

    // MARK: Generic bool toggle (drop-on-default)

    static func settingBool(
        _ value: Bool, key: String, default def: Bool, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if value == def {
            next.options.removeValue(forKey: key)
        } else {
            next.options[key] = .bool(value)
        }
        return next
    }
}
