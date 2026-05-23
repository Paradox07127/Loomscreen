#if !LITE_BUILD
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Pro-only inspector card that mirrors Wallpaper Engine's right-hand
/// property panel for an imported web project. Hidden in Lite via the
/// `#if !LITE_BUILD` wrapper (the SPM source-file layout would otherwise
/// pull this view into the lightweight runtime, even though the Lite
/// capability catalog has no `wpeImport`).
struct WPEProjectCustomSettingsCard: View {
    var screen: Screen
    var schema: WallpaperEngineProjectPropertySchema
    @Binding var config: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager
    @AppStorage("Inspector.WPEProjectCustomSettingsExpanded") private var isExpanded = true

    var body: some View {
        projectSettingsCard(schema)
    }

    private func projectSettingsCard(_ schema: WallpaperEngineProjectPropertySchema) -> some View {
        GroupBox {
            CollapsibleSection(
                title: "Project Custom Settings",
                systemImage: "slider.horizontal.3",
                isExpanded: $isExpanded,
                trailingAccessory: { resetAccessory(for: schema) }
            ) {
                VStack(spacing: 8) {
                    gateNotices(for: schema)
                    propertyList(for: schema)
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    @ViewBuilder
    private func resetAccessory(for schema: WallpaperEngineProjectPropertySchema) -> some View {
        if hasOverrides(for: schema) {
            Button(action: { resetOverrides(for: schema) }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(Text("Reset project custom settings"))
            .accessibilityLabel(Text("Reset project custom settings"))
        }
    }

    @ViewBuilder
    private func gateNotices(for schema: WallpaperEngineProjectPropertySchema) -> some View {
        if !config.allowJavaScript {
            WPEProjectNotice(
                icon: "curlybraces",
                text: "JavaScript is off, so project settings cannot reach this wallpaper."
            )
            Divider()
        } else if needsMouseInput(schema), !config.allowMouseInteraction {
            HStack(spacing: 8) {
                WPEProjectNotice(
                    icon: "cursorarrow.click",
                    text: "Page Input is off; mouse-related project options may not react."
                )

                Button("Enable") {
                    var next = config
                    next.allowMouseInteraction = true
                    apply(next)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
            Divider()
        }

        if config.muteAudio, needsAudio(schema) {
            WPEProjectNotice(
                icon: "speaker.slash",
                text: "Master Audio is muted; project volume options still update the wallpaper."
            )
            Divider()
        }
    }

    private func propertyList(for schema: WallpaperEngineProjectPropertySchema) -> some View {
        let values = schema.effectiveValues(overrides: config.wallpaperEngineProjectProperties)
        let visibleProperties = schema.visibleProperties(values: values)

        return VStack(spacing: 8) {
            ForEach(visibleProperties) { property in
                propertyView(for: property, values: values)

                if property.id != visibleProperties.last?.id {
                    Divider()
                }
            }
        }
        .disabled(!config.allowJavaScript)
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
                    // Author shipped a combo with no `options[]`. There is
                    // nothing the user can switch between — mark as
                    // unavailable instead of rendering an empty Picker.
                    Text(verbatim: currentValue.stringValue)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: valueBinding(for: property)) {
                        // If the persisted value lies outside the option
                        // set, surface it as a synthetic "Custom (…)" tag
                        // so the Picker still has a matching selection and
                        // the user can see why their override looks
                        // foreign.
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
                }
            }
        case .color:
            WPEProjectSettingRow(icon: "paintpalette", iconColor: .pink, title: property.displayText) {
                ColorPicker("", selection: colorBinding(for: property), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
            }
        case .textinput:
            WPEProjectSettingRow(icon: "text.cursor", iconColor: .teal, title: property.displayText) {
                TextField("", text: stringBinding(for: property))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 132)
                    .controlSize(.small)
            }
        case .file, .directory:
            // WPE web projects expect to load arbitrary local paths
            // through `applyUserProperties`, but our `WKWebView` only has
            // read access scoped to the project folder via
            // `FolderURLSchemeHandler`. Picking an outside path would
            // silently fail at the WebKit boundary, so the row is shown
            // as informational only — no picker — until we ship a
            // proper sandbox bridge.
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
        case .bool:
            return .bool(false)
        case .slider:
            return .number(property.minimum ?? 0)
        case .combo:
            return property.options.first?.value ?? .string("")
        case .color:
            return .string("1 1 1")
        case .textinput, .file, .directory, .text, .group, .unsupported:
            return .string("")
        }
    }

    private func valueBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<WallpaperEngineProjectPropertyValue> {
        Binding(
            get: {
                config.wallpaperEngineProjectProperties[property.key]
                    ?? property.defaultValue
                    ?? fallbackValue(for: property)
            },
            set: { setProjectValue($0, for: property) }
        )
    }

    private func boolBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<Bool> {
        Binding(
            get: { valueBinding(for: property).wrappedValue.boolValue ?? false },
            set: { setProjectValue(.bool($0), for: property) }
        )
    }

    private func numberBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<Double> {
        Binding(
            get: {
                let raw = valueBinding(for: property).wrappedValue.numberValue
                    ?? property.minimum
                    ?? 0
                return clamp(raw, to: sliderRange(for: property))
            },
            set: { setProjectValue(.number(normalizedSliderValue($0, for: property)), for: property) }
        )
    }

    private func stringBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<String> {
        Binding(
            get: { valueBinding(for: property).wrappedValue.stringValue },
            set: { setProjectValue(.string($0), for: property) }
        )
    }

    private func colorBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<CGColor> {
        Binding(
            get: { cgColor(from: valueBinding(for: property).wrappedValue.stringValue) },
            set: { setProjectValue(.string(colorString(from: $0)), for: property) }
        )
    }

    private func setProjectValue(
        _ value: WallpaperEngineProjectPropertyValue,
        for property: WallpaperEngineProjectPropertySchema.Property
    ) {
        var next = config
        if Self.matchesDefault(value: value, for: property) {
            next.wallpaperEngineProjectProperties.removeValue(forKey: property.key)
        } else {
            next.wallpaperEngineProjectProperties[property.key] = value
        }
        apply(next)
    }

    /// Type-aware comparison that decides whether a freshly-edited value
    /// should be persisted as an override or treated as "back to default".
    /// Plain `==` on the enum is too strict for two cases:
    ///
    /// 1. **Slider values** — SwiftUI slider math reproduces the default
    ///    `20` as `20.000000000000004` after one round-trip, which would
    ///    permanently mark the slider as overridden.
    /// 2. **Color values** — the ColorPicker may yield `"0.500000 0.500000
    ///    0.500000"` for a default authored as `"0.5 0.5 0.5"`.
    ///
    /// Compare numerically per component within an epsilon so the Reset
    /// affordance and the persisted override set both stay honest.
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
                // Compare the first three (RGB) components only. WPE
                // authors mix `"r g b"`, `"#rrggbb"`, and `"#rrggbbaa"`
                // freely, while SwiftUI's `ColorPicker` (with
                // `supportsOpacity: false`) always rounds-trips three
                // components — without trimming we would mark a default
                // `#808080ff` as "different" from the picker's
                // `"0.5 0.5 0.5"`.
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

    /// Parses the shared `"r g b"` / hex / `#rrggbb` color literal into
    /// 3-4 normalized components so both equality and `cgColor(from:)` go
    /// through the same source of truth.
    private static func colorComponents(from raw: String) -> [Double] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hex = decodeHexColor(trimmed) {
            return hex
        }
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "," })
        let parsed = parts.compactMap { Double($0) }
        guard parsed.count >= 3 else { return [] }
        return parsed.prefix(4).map { min(max($0, 0), 1) }
    }

    /// Recognises WPE's other common color encoding (`"#rrggbb"`,
    /// `"#rrggbbaa"`, or bare `"rrggbb"`) so authors who used either
    /// notation interoperate with the SwiftUI ColorPicker round-trip.
    private static func decodeHexColor(_ raw: String) -> [Double]? {
        var hex = raw.lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        let allowedLengths: Set<Int> = [6, 8]
        guard allowedLengths.contains(hex.count),
              hex.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            return nil
        }
        let pairs = stride(from: 0, to: hex.count, by: 2).map { offset -> Double in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            let byte = UInt8(hex[start..<end], radix: 16) ?? 0
            return Double(byte) / 255.0
        }
        return pairs
    }

    private func apply(_ next: HTMLConfig) {
        guard config != next else { return }
        config = next
        screenManager.updateHTMLConfig(next, for: screen)
    }

    private func resetOverrides(for schema: WallpaperEngineProjectPropertySchema) {
        let keys = Set(schema.properties.map(\.key))
        var next = config
        next.wallpaperEngineProjectProperties = next.wallpaperEngineProjectProperties.filter {
            !keys.contains($0.key)
        }
        apply(next)
    }

    private func hasOverrides(for schema: WallpaperEngineProjectPropertySchema) -> Bool {
        let keys = Set(schema.properties.map(\.key))
        return config.wallpaperEngineProjectProperties.keys.contains { keys.contains($0) }
    }

    private func sliderRange(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> ClosedRange<Double> {
        let lower = property.minimum ?? 0
        let upper = property.maximum ?? max(100, lower + 1)
        if upper > lower { return lower...upper }
        return lower...(lower + 1)
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
        let clamped = clamp01(value)
        return String(format: "%.6g", clamped)
    }

    private func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func needsMouseInput(_ schema: WallpaperEngineProjectPropertySchema) -> Bool {
        schema.properties.contains { property in
            let text = "\(property.key) \(property.displayText)".lowercased()
            return text.contains("mouse")
                || text.contains("click")
                || text.contains("cursor")
                || text.contains("headpat")
                || text.contains("tracking")
                || text.contains("hitbox")
        }
    }

    private func needsAudio(_ schema: WallpaperEngineProjectPropertySchema) -> Bool {
        schema.properties.contains { property in
            let text = "\(property.key) \(property.displayText)".lowercased()
            return text.contains("audio")
                || text.contains("music")
                || text.contains("bgm")
                || text.contains("sound")
                || text.contains("voice")
                || text.contains("volume")
        }
    }
}

private struct WPEProjectSettingRow<Content: View>: View {
    /// Distinguishes author-supplied subtitles (from `project.json`, must be
    /// rendered verbatim) from app-supplied subtitles that need to flow
    /// through the localization catalog.
    enum Subtitle {
        case authorVerbatim(String)
        case localized(LocalizedStringKey)
    }

    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: Subtitle?
    let content: Content

    init(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: Subtitle? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 24, height: 24)
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(iconColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    subtitleText
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            content
        }
        .controlSize(.small)
        .padding(.vertical, 3)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    @ViewBuilder
    private var subtitleText: some View {
        switch subtitle {
        case .authorVerbatim(let raw):
            Text(verbatim: raw)
        case .localized(let key):
            Text(key)
        case .none:
            EmptyView()
        }
    }
}

private struct WPEProjectTextBlock: View {
    let text: String
    let isHeader: Bool

    var body: some View {
        Text(verbatim: text)
            .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
            .foregroundStyle(isHeader ? .primary : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, isHeader ? 2 : 1)
    }
}

private struct WPEProjectNotice: View {
    let icon: String
    /// Always an app-supplied LocalizedStringKey — these gate notices are
    /// authored in source, never sourced from `project.json`, so they
    /// flow through the string catalog and the four bundled languages.
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
