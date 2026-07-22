#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Edits project properties stored directly on a WPE scene descriptor.
struct WPESceneCustomSettingsCard: View {
    private typealias ValueLogic = WPEProjectPropertyValueLogic

    var screen: Screen
    var schema: WallpaperEngineProjectPropertySchema
    @Binding var descriptor: SceneDescriptor

    @Environment(ScreenManager.self) private var screenManager
    @AppStorage("Inspector.WPESceneCustomSettingsExpanded") private var isExpanded = true
    /// Coalesces rapid slider drags into a single apply (~150ms after the last
    /// change) so continuous dragging doesn't fire an apply/reload every frame.
    @State private var sliderDebounceTasks: [String: Task<Void, Never>] = [:]
    @State private var expandedSections: Set<String> = []
    @State private var presentation: WPEProjectSettingsPresentation?
    @State private var settingRows: [WPEProjectSettingsPresentation.Row] = []

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Scene Custom Settings",
                systemImage: "slider.horizontal.3",
                isExpanded: $isExpanded,
                trailingAccessory: {
                    resetAccessory(hasOverrides: presentation?.hasVisibleOverrides ?? false)
                }
            ) {
                if let presentation {
                    settingsList(rows: settingRows, values: presentation.values)
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .onAppear(perform: refreshPresentation)
        .onChange(of: presentationRefreshKey) { _, _ in refreshPresentation() }
        .onDisappear { flushPendingSliderApply() }
    }

    // MARK: - Reset

    @ViewBuilder
    private func resetAccessory(hasOverrides: Bool) -> some View {
        if hasOverrides {
            Button(action: resetOverrides) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
            }
            .buttonStyle(.borderless)
            .help(Text("Reset project custom settings"))
            .accessibilityLabel(Text("Reset project custom settings"))
        }
    }

    private func resetOverrides() {
        apply(descriptor.clearingPropertyOverrides())
    }

    // MARK: - Property list

    private func settingsList(
        rows: [WPEProjectSettingsPresentation.Row],
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> some View {
        let showsSectionAffiliation = rows.contains { row in
            if case .sectionHeader = row { return true }
            return false
        }

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                settingRowView(
                    for: row,
                    values: values,
                    showsDivider: index < rows.count - 1,
                    showsSectionAffiliation: showsSectionAffiliation
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, -10)
    }

    @ViewBuilder
    private func settingRowView(
        for row: WPEProjectSettingsPresentation.Row,
        values: [String: WallpaperEngineProjectPropertyValue],
        showsDivider: Bool,
        showsSectionAffiliation: Bool
    ) -> some View {
        switch row {
        case .sectionHeader(let section):
            rowContainer(showsDivider: showsDivider) {
                sectionHeaderRow(section)
            }
        case .property(let property):
            rowContainer(
                showsDivider: showsDivider,
                showsSectionAffiliation: showsSectionAffiliation
            ) {
                propertyView(for: property, values: values)
            }
        }
    }

    private func rowContainer<Content: View>(
        showsDivider: Bool,
        showsSectionAffiliation: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: showsSectionAffiliation ? 6 : 0) {
            if showsSectionAffiliation {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.blue.opacity(0.72))
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)
            }

            content()
        }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .bottom) {
                if showsDivider {
                    Divider()
                }
            }
    }

    private func sectionHeaderRow(_ section: WPEProjectSettingsPresentation.Section) -> some View {
        let isExpanded = expandedSections.contains(section.id)
        return Button {
            toggleSection(section.id)
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: section.title)
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }

    private static let excludedSceneSettingKeys: Set<String> = ["schemecolor"]

    private var presentationRefreshKey: PresentationRefreshKey {
        PresentationRefreshKey(
            workshopID: descriptor.workshopID,
            cacheRelativePath: descriptor.cacheRelativePath,
            entryFile: descriptor.entryFile,
            propertyOverrides: descriptor.propertyOverrides
        )
    }

    private struct PresentationRefreshKey: Equatable {
        let workshopID: String
        let cacheRelativePath: String
        let entryFile: String
        let propertyOverrides: [String: WallpaperEngineProjectPropertyValue]
    }

    private func refreshPresentation() {
        let next = WPEProjectSettingsPresentation(
            schema: schema,
            overrides: descriptor.propertyOverrides,
            excludedKeys: Self.excludedSceneSettingKeys
        )
        presentation = next
        expandedSections = WPEProjectSettingsPresentation.prunedSectionIDs(
            expandedSections,
            for: next.sections
        )
        settingRows = next.rows(expandedSectionIDs: expandedSections)
    }

    private func toggleSection(_ sectionID: String) {
        if expandedSections.contains(sectionID) {
            expandedSections.remove(sectionID)
        } else {
            expandedSections.insert(sectionID)
        }
        refreshRows()
    }

    private func refreshRows() {
        guard let presentation else { return }
        settingRows = presentation.rows(expandedSectionIDs: expandedSections)
    }

    static func isSceneSettingCandidate(
        _ property: WallpaperEngineProjectPropertySchema.Property
    ) -> Bool {
        !excludedSceneSettingKeys.contains(property.key)
            && isInteractive(property.type)
            && !property.isPromotionalLink
    }

    static func isInteractive(_ type: WallpaperEngineProjectPropertySchema.PropertyType) -> Bool {
        WPEProjectSettingsPresentation.isSceneInteractive(type)
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
                    Text(verbatim: currentValue.stringValue)
                        .font(DesignTokens.Typography.code)
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
        ValueLogic.value(for: property, in: values)
    }

    private func valueBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<WallpaperEngineProjectPropertyValue> {
        Binding(
            get: {
                descriptor.propertyOverrides[property.key]
                    ?? property.defaultValue
                    ?? ValueLogic.fallbackValue(for: property)
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
                return ValueLogic.clamp(raw, to: ValueLogic.sliderRange(for: property))
            },
            set: { setSliderValue(.number(ValueLogic.normalizedSliderValue($0, for: property)), for: property) }
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
            get: { ValueLogic.cgColor(from: valueBinding(for: property).wrappedValue.stringValue) },
            set: { setValue(.string(ValueLogic.colorString(from: $0)), for: property) }
        )
    }

    private func setValue(
        _ value: WallpaperEngineProjectPropertyValue,
        for property: WallpaperEngineProjectPropertySchema.Property
    ) {
        let matchesDefault = ValueLogic.matchesDefault(value: value, for: property)
        let next = descriptor.updating(property: property.key, to: matchesDefault ? nil : value)
        apply(next)
    }

    /// Slider variant of `setValue`: updates `descriptor` immediately so the control tracks the drag, but debounces the `updateSceneDescriptor` call (~150ms) so a continuous drag triggers a single apply/reload.
    private func setSliderValue(
        _ value: WallpaperEngineProjectPropertyValue,
        for property: WallpaperEngineProjectPropertySchema.Property
    ) {
        let matchesDefault = ValueLogic.matchesDefault(value: value, for: property)
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
            await screenManager.updateSceneDescriptor(descriptor, for: screen)
        }
    }

    private func apply(_ next: SceneDescriptor) {
        guard descriptor != next else { return }
        // A discrete change (toggle/picker/color) supersedes any in-flight slider debounce; `next` already includes those slider values because `descriptor` is updated immediately on each drag.
        cancelPendingSliderApplies()
        descriptor = next
        Task { @MainActor in await screenManager.updateSceneDescriptor(next, for: screen) }
    }

    private func cancelPendingSliderApplies() {
        guard !sliderDebounceTasks.isEmpty else { return }
        for task in sliderDebounceTasks.values { task.cancel() }
        sliderDebounceTasks.removeAll()
    }

    private func flushPendingSliderApply() {
        guard !sliderDebounceTasks.isEmpty else { return }
        cancelPendingSliderApplies()
        Task { @MainActor in await screenManager.updateSceneDescriptor(descriptor, for: screen) }
    }

}
#endif
