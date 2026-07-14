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
    private typealias ValueLogic = WPEProjectPropertyValueLogic

    var screen: Screen
    var schema: WallpaperEngineProjectPropertySchema
    var projectKey: String?
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
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
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
        let values = schema.effectiveValues(overrides: projectOverrides)
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
            WPEProjectSettingRow(title: property.displayText) {
                Toggle("", isOn: boolBinding(for: property))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        case .slider:
            WPEProjectSettingRow(title: property.displayText) {
                HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                    Slider(
                        value: numberBinding(for: property),
                        in: ValueLogic.sliderRange(for: property),
                        step: ValueLogic.sliderStep(for: property)
                    )
                    .frame(width: DesignTokens.Inspector.sliderWidth)
                    .controlSize(.small)

                    Text(verbatim: ValueLogic.formattedNumber(value(for: property, values: values).numberValue ?? 0, for: property))
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
                }
            }
        case .combo:
            let currentValue = value(for: property, values: values)
            let optionsCoverCurrent = property.options.contains { $0.value == currentValue }
            WPEProjectSettingRow(title: property.displayText) {
                if property.options.isEmpty {
                    // Author shipped a combo with no `options[]`. There is
                    // nothing the user can switch between — mark as
                    // unavailable instead of rendering an empty Picker.
                    Text(verbatim: currentValue.stringValue)
                        .font(DesignTokens.Typography.code)
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
                    .accessibilityLabel(property.displayText)
                }
            }
        case .color:
            WPEProjectSettingRow(title: property.displayText) {
                ColorPicker("", selection: colorBinding(for: property), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        case .textinput:
            WPEProjectSettingRow(title: property.displayText) {
                TextField("", text: stringBinding(for: property))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 132)
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
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
        ValueLogic.value(for: property, in: values)
    }

    private func valueBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<WallpaperEngineProjectPropertyValue> {
        Binding(
            get: {
                projectOverrides[property.key]
                    ?? property.defaultValue
                    ?? ValueLogic.fallbackValue(for: property)
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
                return ValueLogic.clamp(raw, to: ValueLogic.sliderRange(for: property))
            },
            set: { setProjectValue(.number(ValueLogic.normalizedSliderValue($0, for: property)), for: property) }
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
            get: { ValueLogic.cgColor(from: valueBinding(for: property).wrappedValue.stringValue) },
            set: { setProjectValue(.string(ValueLogic.colorString(from: $0)), for: property) }
        )
    }

    private func setProjectValue(
        _ value: WallpaperEngineProjectPropertyValue,
        for property: WallpaperEngineProjectPropertySchema.Property
    ) {
        var next = config
        var overrides = next.projectWallpaperEngineProperties(forProjectKey: projectKey)
        if ValueLogic.matchesDefault(value: value, for: property) {
            overrides.removeValue(forKey: property.key)
        } else {
            overrides[property.key] = value
        }
        next.setWallpaperEngineProjectProperties(overrides, forProjectKey: projectKey)
        apply(next)
    }

    private func apply(_ next: HTMLConfig) {
        guard config != next else { return }
        config = next
        screenManager.updateHTMLConfig(next, for: screen)
    }

    private func resetOverrides(for schema: WallpaperEngineProjectPropertySchema) {
        let keys = Set(schema.properties.map(\.key))
        var next = config
        let overrides = next.projectWallpaperEngineProperties(forProjectKey: projectKey).filter {
            !keys.contains($0.key)
        }
        next.setWallpaperEngineProjectProperties(overrides, forProjectKey: projectKey)
        apply(next)
    }

    private func hasOverrides(for schema: WallpaperEngineProjectPropertySchema) -> Bool {
        let keys = Set(schema.properties.map(\.key))
        return projectOverrides.keys.contains { keys.contains($0) }
    }

    private var projectOverrides: [String: WallpaperEngineProjectPropertyValue] {
        config.projectWallpaperEngineProperties(forProjectKey: projectKey)
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

#endif
// Shared widgets `WPEProjectSettingRow`, `WPEProjectTextBlock`,
// `WPEProjectNotice` were extracted to `WPEProjectSettingWidgets.swift`
// so the scene-side `WPESceneCustomSettingsCard` can render the same UI.
