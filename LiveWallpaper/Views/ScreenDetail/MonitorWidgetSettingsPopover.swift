import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Per-widget settings popover shown from the inspector's instrument list.
///
/// Native chrome (standard AppKit/SwiftUI controls — SPEC §5.0-a) rather than
/// the board's own matte instrument styling. Every kind gets a size picker (only
/// the sizes `kind.allowedSizes` permits) and a remove button; kinds with tuning
/// add their own controls:
///   • Clock — a seconds toggle and a world-clock editor (up to 2 timezone
///     identifiers), keys `showsSeconds` (.bool) and `worldClocks` (.stringList).
///   • Processes — a row-count stepper (1…8, default 5), key `count` (.number).
///   • CPU/GPU/Memory/Disk — a `historyWindow` trend picker plus each kind's
///     toggles (`showHeatmap`/`showComposition`/`showSensors`,
///     `showLoadBreakdown`, `showTopProcesses`) and the Memory/Disk `breakdown`.
///   • Usage/Fleet — a `provider` filter, plus Usage's `primaryMetric` and
///     Fleet's `fleetSort` / `fleetMaxRows`.
///
/// Writes follow one rule: a value equal to the widget's default drops the key
/// (matching `settingWorldClocks`' empty-list habit) so `options` stays minimal.
///
/// Edits are applied through `onUpdate`, which the inspector persists via
/// `ScreenManager`. `MonitorWidgetDraft` holds the pure option encode/decode so
/// the round-trips are unit-testable without any view.
struct MonitorWidgetSettingsPopover: View {
    let placement: MonitorWidgetPlacement
    let onUpdate: (MonitorWidgetPlacement) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if placement.kind.allowedSizes.count > 1 {
                SettingsSection { sizePicker }
            }

            if hasKindOptions {
                SettingsSection { kindOptions }
            }

            removeButton
        }
        .padding(16)
        .frame(width: 320)
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
        case .clock, .processes, .cpu, .gpu, .memory, .disk, .usage, .fleet: return true
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
        case .clock:
            clockOptions
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

    // MARK: Clock

    private var clockOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { MonitorWidgetDraft.showsSeconds(placement) },
                set: { onUpdate(MonitorWidgetDraft.settingShowsSeconds($0, on: placement)) }
            )) {
                Text("Show seconds")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            worldClocksEditor
        }
    }

    @ViewBuilder
    private var worldClocksEditor: some View {
        let clocks = MonitorWidgetDraft.worldClocks(placement)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("World clocks")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(verbatim: "\(clocks.count)/\(MonitorWidgetDraft.maxWorldClocks)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if placement.size == .small {
                Text("World clocks show on the medium size only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(clocks.enumerated()), id: \.offset) { index, identifier in
                HStack(spacing: 6) {
                    Text(verbatim: Self.cityLabel(identifier))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        onUpdate(MonitorWidgetDraft.removingWorldClock(at: index, on: placement))
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove world clock"))
                }
            }

            if clocks.count < MonitorWidgetDraft.maxWorldClocks {
                TimeZonePicker(
                    excluding: Set(clocks),
                    onPick: { identifier in
                        onUpdate(MonitorWidgetDraft.addingWorldClock(identifier, on: placement))
                    }
                )
            }
        }
    }

    // MARK: Processes

    private var processesOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        VStack(alignment: .leading, spacing: 10) {
            historyWindowPicker(defaultWindow: MonitorCPUDraft.defaultHistoryWindow(for: placement.size))
            Toggle(isOn: boolBinding(key: MonitorCPUDraft.showHeatmapKey, default: true)) {
                Text("Show heatmap")
            }
            .toggleStyle(.switch).controlSize(.small)
            Toggle(isOn: boolBinding(key: MonitorCPUDraft.showCompositionKey, default: true)) {
                Text("Show composition")
            }
            .toggleStyle(.switch).controlSize(.small)
            Toggle(isOn: boolBinding(key: MonitorCPUDraft.showSensorsKey, default: true)) {
                Text("Show sensors")
            }
            .toggleStyle(.switch).controlSize(.small)
        }
    }

    // MARK: GPU

    private var gpuOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            historyWindowPicker(defaultWindow: 60)
            Toggle(isOn: boolBinding(key: MonitorWidgetDraft.showLoadBreakdownKey, default: true)) {
                Text("Show load breakdown")
            }
            .toggleStyle(.switch).controlSize(.small)
            Toggle(isOn: boolBinding(key: MonitorWidgetDraft.showSensorsKey, default: true)) {
                Text("Show sensors")
            }
            .toggleStyle(.switch).controlSize(.small)
        }
    }

    // MARK: Memory

    private var memoryOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            historyWindowPicker(defaultWindow: placement.size == .large ? 120 : 60)
            breakdownPicker
            Toggle(isOn: boolBinding(key: MonitorWidgetDraft.showTopProcessesKey, default: true)) {
                Text("Show top processes")
            }
            .toggleStyle(.switch).controlSize(.small)
            if placement.size != .large {
                Text("Top processes show on the large size only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Disk

    private var diskOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            historyWindowPicker(defaultWindow: 120)
            breakdownPicker
        }
    }

    // MARK: Usage

    private var usageOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            providerPicker(key: MonitorWidgetDraft.usageProviderKey)
            primaryMetricPicker
        }
    }

    // MARK: Fleet

    private var fleetOptions: some View {
        let fallback = placement.size == .large ? 6 : 3
        return VStack(alignment: .leading, spacing: 10) {
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

    // MARK: - Labels

    static func sizeLabel(_ size: MonitorWidgetSize) -> String {
        switch size {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// "America/New_York" → "New York" for display; identifiers are stored raw.
    static func cityLabel(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier)
            .replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - Grouped glass section

/// An Apple-style grouped card: its rows sit on a Liquid-Glass surface (macOS 26+)
/// that degrades to a `.regularMaterial` fill on earlier systems and an opaque fill
/// under Reduce Transparency — all handled by `adaptiveGlassSurface`.
private struct SettingsSection<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlassSurface(.roundedRectangle(12))
    }
}

// MARK: - Timezone picker

/// A searchable menu over `TimeZone.knownTimeZoneIdentifiers`, minus already
/// chosen zones. Kept small: a text field filters, a scrolling list picks.
private struct TimeZonePicker: View {
    let excluding: Set<String>
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Add world clock", systemImage: "plus.circle")
        }
        .controlSize(.small)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search city…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches, id: \.self) { identifier in
                            Button {
                                onPick(identifier)
                                isPresented = false
                                query = ""
                            } label: {
                                Text(verbatim: MonitorWidgetSettingsPopover.cityLabel(identifier))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 220, height: 220)
            }
            .padding(10)
        }
    }

    private var matches: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.filter { !excluding.contains($0) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        let needle = trimmed.lowercased()
        return all.filter { $0.lowercased().contains(needle) }
    }
}

// MARK: - Pure draft mutations (unit-tested)

/// Pure encode/decode of a placement's option bag for the settings popover. Kept
/// free of any view type so the round-trips are unit-testable. Each mutator
/// returns a NEW placement with the option written under the key the widget
/// reads (verified against `MonitorClockWidgetView` / `MonitorProcessesWidgetView`).
enum MonitorWidgetDraft {
    static let showsSecondsKey = "showsSeconds"
    static let worldClocksKey = "worldClocks"
    static let countKey = "count"

    static let maxWorldClocks = 2
    static let processCountRange = 1...8
    static let defaultProcessCount = 5

    // MARK: Clock · seconds

    static func showsSeconds(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[showsSecondsKey]?.boolValue ?? false
    }

    static func settingShowsSeconds(
        _ value: Bool, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        next.options[showsSecondsKey] = .bool(value)
        return next
    }

    // MARK: Clock · world clocks

    static func worldClocks(_ placement: MonitorWidgetPlacement) -> [String] {
        Array((placement.options[worldClocksKey]?.stringListValue ?? []).prefix(maxWorldClocks))
    }

    static func addingWorldClock(
        _ identifier: String, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var list = worldClocks(placement)
        guard !list.contains(identifier), list.count < maxWorldClocks else { return placement }
        list.append(identifier)
        return settingWorldClocks(list, on: placement)
    }

    static func removingWorldClock(
        at index: Int, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var list = worldClocks(placement)
        guard list.indices.contains(index) else { return placement }
        list.remove(at: index)
        return settingWorldClocks(list, on: placement)
    }

    static func settingWorldClocks(
        _ list: [String], on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if list.isEmpty {
            next.options.removeValue(forKey: worldClocksKey)
        } else {
            next.options[worldClocksKey] = .stringList(Array(list.prefix(maxWorldClocks)))
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
