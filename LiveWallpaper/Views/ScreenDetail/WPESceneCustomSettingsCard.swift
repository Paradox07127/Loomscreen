#if !LITE_BUILD
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Pro-only inspector card that mirrors Wallpaper Engine's right-hand
/// property panel for an imported `.scene` workshop project.
///
/// Companion to the HTML project settings card.
/// The two diverge on three points:
///   - storage: scene overrides live on `SceneDescriptor.propertyOverrides`
///     rather than `HTMLConfig.wallpaperEngineProjectPropertiesByProject`
///     because there's no parent HTMLConfig in the `.scene(...)`
///     wallpaper case;
///   - the apply path goes through `ScreenManager.updateSceneDescriptor`
///     instead of `updateHTMLConfig`;
///   - `schemecolor` is *included* in the schema (the scene renderer
///     consumes it via Phase B uniform injection; the HTML inspector
///     hides it because CSS already paints it).
///
/// All widget rendering (bool/slider/combo/color/textinput/group/text)
/// matches the HTML card pixel-for-pixel so the two inspectors feel
/// like one feature wearing two coats.
struct WPESceneCustomSettingsCard: View {
    var screen: Screen
    var schema: WallpaperEngineProjectPropertySchema
    @Binding var descriptor: SceneDescriptor

    @Environment(ScreenManager.self) private var screenManager
    @AppStorage("Inspector.WPESceneCustomSettingsExpanded") private var isExpanded = true
    /// Per-property debounce tasks coalescing rapid slider drags into a single
    /// apply (~150ms after the last change) so continuous dragging doesn't fire
    /// an apply/reload every frame.
    @State private var sliderDebounceTasks: [String: Task<Void, Never>] = [:]

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Project Custom Settings",
                systemImage: "slider.horizontal.3",
                isExpanded: $isExpanded,
                trailingAccessory: { resetAccessory }
            ) {
                propertyList
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .onDisappear { flushPendingSliderApply() }
    }

    // MARK: - Reset

    @ViewBuilder
    private var resetAccessory: some View {
        if hasOverrides {
            Button(action: resetOverrides) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(Text("Reset project custom settings"))
            .accessibilityLabel(Text("Reset project custom settings"))
        }
    }

    private var hasOverrides: Bool {
        let keys = Set(schema.properties.map(\.key))
        return descriptor.propertyOverrides.keys.contains { keys.contains($0) }
    }

    private func resetOverrides() {
        apply(descriptor.clearingPropertyOverrides())
    }

    // MARK: - Property list

    private var propertyList: some View {
        let values = schema.effectiveValues(overrides: descriptor.propertyOverrides)
        // Only genuinely interactive controls. Real WPE projects pad
        // `properties` with HTML promo/donation blocks (`text`), decorative
        // section headers (`group`), and macOS-unsupported file/directory
        // pickers — none of which the user can act on. Drop them so the column
        // is a clean list of changeable options.
        let interactive = schema.visibleProperties(values: values).filter { Self.isInteractive($0.type) }

        return VStack(spacing: 8) {
            ForEach(interactive) { property in
                propertyView(for: property, values: values)
                if property.id != interactive.last?.id {
                    Divider()
                }
            }
        }
    }

    static func isInteractive(_ type: WallpaperEngineProjectPropertySchema.PropertyType) -> Bool {
        switch type {
        case .bool, .slider, .combo, .color, .textinput: return true
        case .file, .directory, .group, .text, .unsupported: return false
        }
    }

    @ViewBuilder
    private func propertyView(
        for property: WallpaperEngineProjectPropertySchema.Property,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> some View {
        switch property.type {
        case .bool:
            WPEProjectSettingRow(icon: "checkmark.square", iconColor: .green, title: property.displayText) {
                Toggle("", isOn: boolBinding(for: property))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        case .slider:
            WPEProjectSettingRow(icon: "slider.horizontal.3", iconColor: .blue, title: property.displayText) {
                HStack(spacing: 6) {
                    Slider(
                        value: numberBinding(for: property),
                        in: sliderRange(for: property),
                        step: sliderStep(for: property)
                    )
                    .frame(width: 96)
                    .controlSize(.small)

                    Text(verbatim: formattedNumber(value(for: property, values: values).numberValue ?? 0, for: property))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                        .monospacedDigit()
                }
            }
        case .combo:
            let currentValue = value(for: property, values: values)
            let optionsCoverCurrent = property.options.contains { $0.value == currentValue }
            WPEProjectSettingRow(icon: "list.bullet.rectangle", iconColor: .purple, title: property.displayText) {
                if property.options.isEmpty {
                    Text(verbatim: currentValue.stringValue)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: valueBinding(for: property)) {
                        if !optionsCoverCurrent {
                            Text(verbatim: "·  \(currentValue.stringValue)")
                                .tag(currentValue)
                        }
                        ForEach(property.options) { option in
                            Text(verbatim: option.displayLabel)
                                .tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel(property.displayText)
                }
            }
        case .color:
            WPEProjectSettingRow(icon: "paintpalette", iconColor: .pink, title: property.displayText) {
                ColorPicker("", selection: colorBinding(for: property), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        case .textinput:
            WPEProjectSettingRow(icon: "text.cursor", iconColor: .teal, title: property.displayText) {
                TextField("", text: stringBinding(for: property))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 132)
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        case .file, .directory:
            WPEProjectSettingRow(
                icon: property.type == .file ? "doc.badge.plus" : "folder.badge.plus",
                iconColor: .secondary,
                title: property.displayText,
                subtitle: .localized("Not supported on macOS yet")
            ) {
                EmptyView()
            }
            .disabled(true)
            .opacity(0.55)
        case .group:
            WPEProjectTextBlock(text: property.displayText, isHeader: true)
        case .text:
            WPEProjectTextBlock(text: property.displayText, isHeader: false)
        case .unsupported:
            EmptyView()
        }
    }

    // MARK: - Bindings

    private func value(
        for property: WallpaperEngineProjectPropertySchema.Property,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> WallpaperEngineProjectPropertyValue {
        values[property.key] ?? fallbackValue(for: property)
    }

    private func fallbackValue(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> WallpaperEngineProjectPropertyValue {
        switch property.type {
        case .bool: return .bool(false)
        case .slider: return .number(property.minimum ?? 0)
        case .combo: return property.options.first?.value ?? .string("")
        case .color: return .string("1 1 1")
        case .textinput, .file, .directory, .text, .group, .unsupported: return .string("")
        }
    }

    private func valueBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<WallpaperEngineProjectPropertyValue> {
        Binding(
            get: {
                descriptor.propertyOverrides[property.key]
                    ?? property.defaultValue
                    ?? fallbackValue(for: property)
            },
            set: { setValue($0, for: property) }
        )
    }

    private func boolBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<Bool> {
        Binding(
            get: { valueBinding(for: property).wrappedValue.boolValue ?? false },
            set: { setValue(.bool($0), for: property) }
        )
    }

    private func numberBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<Double> {
        Binding(
            get: {
                let raw = valueBinding(for: property).wrappedValue.numberValue
                    ?? property.minimum ?? 0
                return clamp(raw, to: sliderRange(for: property))
            },
            set: { setSliderValue(.number(normalizedSliderValue($0, for: property)), for: property) }
        )
    }

    private func stringBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<String> {
        Binding(
            get: { valueBinding(for: property).wrappedValue.stringValue },
            set: { setValue(.string($0), for: property) }
        )
    }

    private func colorBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<CGColor> {
        Binding(
            get: { cgColor(from: valueBinding(for: property).wrappedValue.stringValue) },
            set: { setValue(.string(colorString(from: $0)), for: property) }
        )
    }

    private func setValue(
        _ value: WallpaperEngineProjectPropertyValue,
        for property: WallpaperEngineProjectPropertySchema.Property
    ) {
        let matchesDefault = Self.matchesDefault(value: value, for: property)
        let next = descriptor.updating(property: property.key, to: matchesDefault ? nil : value)
        apply(next)
    }

    /// Slider variant of `setValue`: updates `descriptor` immediately so the
    /// control tracks the drag, but debounces the `updateSceneDescriptor` call
    /// (~150ms) so a continuous drag triggers a single apply/reload.
    private func setSliderValue(
        _ value: WallpaperEngineProjectPropertyValue,
        for property: WallpaperEngineProjectPropertySchema.Property
    ) {
        let matchesDefault = Self.matchesDefault(value: value, for: property)
        let next = descriptor.updating(property: property.key, to: matchesDefault ? nil : value)
        guard descriptor != next else { return }
        descriptor = next
        let key = property.key
        sliderDebounceTasks[key]?.cancel()
        sliderDebounceTasks[key] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            sliderDebounceTasks[key] = nil
            // Read the live descriptor so concurrent slider drags converge on
            // the latest accumulated value rather than a stale snapshot.
            screenManager.updateSceneDescriptor(descriptor, for: screen)
        }
    }

    private func apply(_ next: SceneDescriptor) {
        guard descriptor != next else { return }
        // A discrete change (toggle/picker/color) supersedes any in-flight
        // slider debounce; `next` already includes those slider values because
        // `descriptor` is updated immediately on each drag.
        cancelPendingSliderApplies()
        descriptor = next
        screenManager.updateSceneDescriptor(next, for: screen)
    }

    private func cancelPendingSliderApplies() {
        guard !sliderDebounceTasks.isEmpty else { return }
        for task in sliderDebounceTasks.values { task.cancel() }
        sliderDebounceTasks.removeAll()
    }

    private func flushPendingSliderApply() {
        guard !sliderDebounceTasks.isEmpty else { return }
        cancelPendingSliderApplies()
        screenManager.updateSceneDescriptor(descriptor, for: screen)
    }

    // MARK: - Equality (color/number tolerance)

    private static func matchesDefault(
        value: WallpaperEngineProjectPropertyValue,
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Bool {
        guard let defaultValue = property.defaultValue else { return false }
        let tolerance = 1e-6

        switch (defaultValue, value) {
        case (.bool(let lhs), .bool(let rhs)):
            return lhs == rhs
        case (.number(let lhs), .number(let rhs)):
            return abs(lhs - rhs) <= tolerance
        case (.string(let lhs), .string(let rhs)):
            if property.type == .color {
                let lhsComponents = colorComponents(from: lhs)
                let rhsComponents = colorComponents(from: rhs)
                guard lhsComponents.count >= 3, rhsComponents.count >= 3 else {
                    return lhs == rhs
                }
                return zip(lhsComponents.prefix(3), rhsComponents.prefix(3))
                    .allSatisfy { abs($0 - $1) <= tolerance }
            }
            return lhs == rhs
        default:
            return defaultValue == value
        }
    }

    private static func colorComponents(from raw: String) -> [Double] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hex = decodeHexColor(trimmed) { return hex }
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "," })
        let parsed = parts.compactMap { Double($0) }
        guard parsed.count >= 3 else { return [] }
        return parsed.prefix(4).map { min(max($0, 0), 1) }
    }

    private static func decodeHexColor(_ raw: String) -> [Double]? {
        var hex = raw.lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard [6, 8].contains(hex.count),
              hex.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            return nil
        }
        return stride(from: 0, to: hex.count, by: 2).map { offset -> Double in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            let byte = UInt8(hex[start..<end], radix: 16) ?? 0
            return Double(byte) / 255.0
        }
    }

    private func sliderRange(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> ClosedRange<Double> {
        let lower = property.minimum ?? 0
        let upper = property.maximum ?? max(100, lower + 1)
        return upper > lower ? lower...upper : lower...(lower + 1)
    }

    private func sliderStep(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Double {
        if let step = property.step, step > 0 { return step }
        return property.fraction ? 0.1 : 1
    }

    private func normalizedSliderValue(
        _ raw: Double,
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Double {
        let range = sliderRange(for: property)
        let clamped = clamp(raw, to: range)
        let step = sliderStep(for: property)
        guard step > 0 else { return clamped }
        let stepped = ((clamped - range.lowerBound) / step).rounded() * step + range.lowerBound
        return clamp(stepped, to: range)
    }

    private func formattedNumber(
        _ value: Double,
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> String {
        let decimals = property.fraction ? min(max(property.precision ?? 1, 0), 4) : 0
        return String(format: "%.\(decimals)f", value)
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func cgColor(from string: String) -> CGColor {
        let components = Self.colorComponents(from: string)
        guard components.count >= 3 else {
            return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        return CGColor(
            red: clamp01(components[0]),
            green: clamp01(components[1]),
            blue: clamp01(components[2]),
            alpha: 1
        )
    }

    private func colorString(from color: CGColor) -> String {
        let converted: CGColor
        if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
           let srgb = color.converted(to: colorSpace, intent: .defaultIntent, options: nil) {
            converted = srgb
        } else {
            converted = color
        }
        let components = converted.components ?? [1, 1, 1]
        let red: Double
        let green: Double
        let blue: Double
        if components.count >= 3 {
            red = Double(components[0])
            green = Double(components[1])
            blue = Double(components[2])
        } else {
            red = Double(components.first ?? 1)
            green = red
            blue = red
        }
        return "\(trimmedColor(red)) \(trimmedColor(green)) \(trimmedColor(blue))"
    }

    private func trimmedColor(_ value: Double) -> String {
        String(format: "%.6g", clamp01(value))
    }

    private func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
#endif
