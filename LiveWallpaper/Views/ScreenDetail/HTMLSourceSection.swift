import SwiftUI
import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI

/// Picker and options for URL- or locally-backed HTML wallpapers. The
/// File vs. Folder distinction collapsed into a single "Local" segment —
/// picking a single .html alone leaves sibling JS/CSS/images unreachable,
/// so we always bookmark the parent folder and use the picked file name
/// as the index, matching folder-mode behavior. Legacy `.file` saves keep
/// loading via their original bookmark for back-compat.
struct HTMLSourceSection: View {
    var screen: Screen
    @Binding var source: HTMLSource?
    @Binding var config: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trustStore = TrustedHostStore.shared

    @State private var selectedSegment: SourceSegment = .url
    @State private var urlInput: String = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer(minLength: 0)
                    sourceSegmentPicker
                        .frame(maxWidth: 200)
                    Spacer(minLength: 0)
                }

                sourcePane
                    .animation(.snappy(duration: 0.18), value: selectedSegment)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .onAppear { scheduleBindingSync() }
        .onChange(of: source) { _, _ in
            scheduleBindingSync()
        }
    }

    // MARK: - Segment Picker

    private enum SourceSegment: String, CaseIterable, Identifiable {
        case url, local
        var id: String { rawValue }

        var labelKey: LocalizedStringKey {
            switch self {
            case .url: return "URL"
            case .local: return "Local"
            }
        }
    }

    private var sourceSegmentPicker: some View {
        HStack(spacing: 0) {
            ForEach(SourceSegment.allCases) { segment in
                Button {
                    let animation = DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))
                    withAnimation(animation) {
                        selectedSegment = segment
                    }
                } label: {
                    Text(segment.labelKey)
                        .font(.system(size: 12, weight: selectedSegment == segment ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(selectedSegment == segment ? Color.accentColor.opacity(0.35) : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(segment.labelKey))
                .accessibilityAddTraits(selectedSegment == segment ? .isSelected : [])
            }
        }
        .padding(2)
        .adaptiveGlassSurface(.capsule, interactive: true)
    }

    // MARK: - Source Pane

    @ViewBuilder
    private var sourcePane: some View {
        switch selectedSegment {
        case .url: urlField
        case .local: localPickerRow
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("https://example.com or example.com", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitURL() }

                Button(action: pasteFromClipboard) {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help(Text("Paste URL from clipboard"))
                .accessibilityLabel(Text("Paste URL from clipboard"))

                Button("Use") { commitURL() }
                    .adaptiveGlassButton(.prominent)
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            urlChipsRow
        }
    }

    /// Reads a URL/host string off the system pasteboard and offers it as the
    /// next URL input. Commits immediately when the pasted value already
    /// parses as a valid `HTMLSource.url`; otherwise just populates the field
    /// so the user can edit before clicking Use.
    private func pasteFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        urlInput = trimmed
        if case .url = HTMLSource(userInput: trimmed) {
            commitURL()
        }
    }

    private var localPickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                summaryLine(
                    icon: localIconName,
                    text: localSummary.map { Text(verbatim: $0) } ?? Text("No file or folder chosen")
                )
                Spacer()
                Button("Choose…") { pickLocal() }
                    .buttonStyle(.bordered)
            }

            sourceChipsRow
        }
    }

    private var localIconName: String {
        switch source {
        case .file: return "doc.richtext"
        case .folder: return "folder"
        default: return "doc.richtext"
        }
    }

    private var localSummary: String? {
        switch source {
        case .file, .folder: return source?.displayName
        default: return nil
        }
    }

    @ViewBuilder
    private func summaryLine(icon: String, text: Text) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            text
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Chips

    @ViewBuilder
    private var urlChipsRow: some View {
        if let source {
            HStack(spacing: 6) {
                if source.isInsecureURL {
                    insecureChip
                }
                trustStatusChip(for: source)
                multiInstanceChip(for: source)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var sourceChipsRow: some View {
        if let source {
            HStack(spacing: 6) {
                multiInstanceChip(for: source)
                Spacer(minLength: 0)
            }
        }
    }

    private var insecureChip: some View {
        chip(
            symbol: "exclamationmark.shield",
            text: "HTTP",
            color: .orange,
            help: "Insecure HTTP — content cannot be verified."
        )
    }

    @ViewBuilder
    private func trustStatusChip(for source: HTMLSource) -> some View {
        let trust = HTMLTrust.evaluate(source: source, trustedOrigins: trustStore.originSet)
        switch trust {
        case .localContent:
            EmptyView()
        case .trustedRemote:
            chip(
                symbol: "checkmark.shield.fill",
                text: "Trusted",
                color: .green,
                help: "JavaScript allowed for this origin."
            )
        case .untrustedRemote:
            chip(
                symbol: "exclamationmark.shield",
                text: "Untrusted",
                color: .orange,
                help: "Scripts disabled. Manage in Content Security panel."
            )
        }
    }

    @ViewBuilder
    private func multiInstanceChip(for source: HTMLSource) -> some View {
        let others = screenManager.screensRunningSameHTMLSource(as: source, excluding: screen.id)
        if !others.isEmpty {
            let names = others.map(\.name).joined(separator: ", ")
            let total = others.count + 1
            chip(
                symbol: "rectangle.on.rectangle.angled",
                label: Text("\(total)× Active", comment: "URL chip showing the number of screens running the same HTML wallpaper."),
                color: .indigo,
                help: Text("Also active on: \(names)")
            )
        }
    }

    @ViewBuilder
    private func chip(
        symbol: String,
        text: LocalizedStringKey,
        color: Color,
        help: LocalizedStringKey
    ) -> some View {
        chip(symbol: symbol, label: Text(text), color: color, help: Text(help))
    }

    @ViewBuilder
    private func chip(
        symbol: String,
        label: Text,
        color: Color,
        help: Text
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            label
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .help(help)
    }

    // MARK: - Actions

    private func scheduleBindingSync() {
        DispatchQueue.main.async {
            Task { @MainActor in
                syncFromBinding()
            }
        }
    }

    private func commitURL() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = HTMLSource(userInput: trimmed) else { return }
        screenManager.setHTMLWallpaper(source: parsed, config: config, for: screen)
    }

    /// Single panel that accepts either a `.html` file or a folder. When the
    /// user picks a file we delegate to `htmlSourceFromPickedFile` so the
    /// bookmark can be promoted to the parent folder (granting sibling JS /
    /// CSS / image access); a folder selection falls through to the index
    /// inference path. Either way the resulting `HTMLSource` is committed.
    private func pickLocal() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedHTMLContentTypes
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else { return }

        if isDirectory.boolValue {
            guard let bookmark = ResourceUtilities.createBookmark(for: url) else { return }
            let indexFileName = inferIndexFileName(in: url)
            screenManager.setHTMLWallpaper(
                source: .folder(bookmarkData: bookmark, indexFileName: indexFileName),
                config: config,
                for: screen
            )
            return
        }

        guard let source = ResourceUtilities.htmlSourceFromPickedFile(url) else { return }
        screenManager.setHTMLWallpaper(source: source, config: config, for: screen)
    }

    // MARK: - Helpers

    private func syncFromBinding() {
        guard let source else {
            if selectedSegment != .url { selectedSegment = .url }
            if !urlInput.isEmpty { urlInput = "" }
            return
        }
        switch source {
        case .url(let url):
            if selectedSegment != .url { selectedSegment = .url }
            if urlInput != url.absoluteString { urlInput = url.absoluteString }
        case .file, .folder:
            if selectedSegment != .local { selectedSegment = .local }
        case .inline(let html):
            if selectedSegment != .url { selectedSegment = .url }
            if urlInput != html { urlInput = html }
        }
    }

    private func inferIndexFileName(in folder: URL) -> String {
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return ResourceUtilities.inferHTMLIndexFileName(from: entries)
    }
}

/// HTML-side analog of the Video inspector groups. Lives in the right-hand
/// inspector column directly under `ContentSecurityInspector`; toggle-style
/// behavior settings stay visually separate from the continuous geometry
/// controls in `HTMLTransformInspector`.
struct HTMLOptionsInspector: View {
    var screen: Screen
    @Binding var config: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager
    @AppStorage("Inspector.HTMLOptionsExpanded") private var isExpanded = true
    @State private var customCSSPresented: Bool = false
    @State private var draftCustomCSS: String = ""

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "HTML Options",
                systemImage: "globe",
                isExpanded: $isExpanded
            ) {
                VStack(spacing: 8) {
                    javaScriptRow
                    Divider()
                    mouseInteractionRow
                    Divider()
                    physicalPixelRow
                    Divider()
                    autoRefreshRow
                    Divider()
                    customCSSRow
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    // MARK: - Rows

    private var javaScriptRow: some View {
        SettingRow(
            icon: "curlybraces",
            iconColor: .orange,
            title: "JavaScript"
        ) {
            Toggle("", isOn: configBinding(\.allowJavaScript))
                .labelsHidden()
                .accessibilityLabel(Text("JavaScript"))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var mouseInteractionRow: some View {
        SettingRow(
            icon: "cursorarrow.click",
            iconColor: .blue,
            title: "Mouse Interaction",
            info: "When on, clicks and scrolls reach the wallpaper but desktop icons and the Dock become unclickable. Off lets you use Finder normally."
        ) {
            Toggle("", isOn: configBinding(\.allowMouseInteraction))
                .labelsHidden()
                .accessibilityLabel(Text("Mouse Interaction"))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var physicalPixelRow: some View {
        SettingRow(
            icon: "rectangle.split.2x1",
            iconColor: .indigo,
            title: "Physical-pixel layout",
            info: "Renders WebGL content at retina resolution so character art and Spine wallpapers stop looking soft. Auto-enabled for imported project folders."
        ) {
            Toggle("", isOn: configBinding(\.physicalPixelLayout))
                .labelsHidden()
                .accessibilityLabel(Text("Physical-pixel layout"))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    /// Refresh interval picker. `0` (Off) is the default — most wallpaper
    /// content is animation/canvas-driven and doesn't benefit from a reload.
    /// The presets cover the common dashboard / weather-page cases.
    private var autoRefreshRow: some View {
        SettingRow(
            icon: "arrow.clockwise",
            iconColor: .cyan,
            title: "Auto Refresh",
            info: "Reloads the page at the chosen interval. Useful for dashboards or feeds; off keeps the page rendering continuously without reloads."
        ) {
            Picker(
                "",
                selection: configBinding(\.refreshIntervalSeconds, normalize: HTMLConfig.clampedRefreshInterval)
            ) {
                Text("Off").tag(0)
                Text("Every 1 min").tag(60)
                Text("Every 5 min").tag(300)
                Text("Every 30 min").tag(1800)
                Text("Every 1 hour").tag(3600)
                Text("Every 6 hours").tag(21600)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Auto-refresh interval"))
        }
    }

    /// Custom CSS row — the editor opens in a popover so the inspector list
    /// stays compact while still giving the user a comfortable multi-line
    /// editing surface. Subtitle + filled icon signal the active state.
    /// `.fixedSize()` keeps the `Edit…` label readable when the title +
    /// subtitle column squeezes the trailing button area.
    private var customCSSRow: some View {
        let isActive = !(config.customCSS ?? "").isEmpty
        return SettingRow(
            icon: isActive ? "paintbrush.fill" : "paintbrush",
            iconColor: .pink,
            title: "Custom CSS",
            subtitle: isActive ? "Style overrides active" : nil
        ) {
            Button {
                customCSSPresented = true
            } label: {
                Text("Edit…")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .popover(isPresented: $customCSSPresented, arrowEdge: .leading) {
                customCSSEditor
            }
        }
        .onAppear { scheduleCustomCSSDraftSync(config.customCSS) }
        .onChange(of: config.customCSS) { _, newValue in
            scheduleCustomCSSDraftSync(newValue)
        }
    }

    private var customCSSEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Custom CSS", systemImage: "paintbrush")
                .font(.headline)

            TextEditor(text: $draftCustomCSS)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 380, height: 200)
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Reset") {
                    draftCustomCSS = config.customCSS ?? ""
                }
                .controlSize(.small)
                .disabled(draftCustomCSS == (config.customCSS ?? ""))

                Spacer()

                Button("Close") { customCSSPresented = false }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    let next = draftCustomCSS.isEmpty ? nil : draftCustomCSS
                    if config.customCSS != next {
                        config.customCSS = next
                        screenManager.updateHTMLConfig(config, for: screen)
                    }
                    customCSSPresented = false
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draftCustomCSS == (config.customCSS ?? ""))
            }
        }
        .padding(14)
    }

    // MARK: - Bindings

    private func configBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<HTMLConfig, Value>,
        normalize: @escaping (Value) -> Value = { $0 }
    ) -> Binding<Value> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { rawValue in
                let newValue = normalize(rawValue)
                guard config[keyPath: keyPath] != newValue else { return }
                var next = config
                next[keyPath: keyPath] = newValue
                config = next
                screenManager.updateHTMLConfig(next, for: screen)
            }
        )
    }

    // MARK: - Helpers

    private func scheduleCustomCSSDraftSync(_ customCSS: String?) {
        DispatchQueue.main.async {
            Task { @MainActor in
                let nextValue = customCSS ?? ""
                if draftCustomCSS != nextValue {
                    draftCustomCSS = nextValue
                }
            }
        }
    }
}

/// Transform inspector — Scale / Translate / Rotation. Reset lives in the
/// CollapsibleSection trailing accessory so a destructive action stays
/// reachable from any scroll position without crowding the value rows.
struct HTMLTransformInspector: View {
    var screen: Screen
    @Binding var config: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager
    @AppStorage("Inspector.HTMLTransformExpanded") private var isExpanded = true

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Transform",
                systemImage: "slider.horizontal.3",
                isExpanded: $isExpanded,
                trailingAccessory: { resetAccessory }
            ) {
                VStack(spacing: 8) {
                    scaleRow
                    Divider()
                    translateRow
                    Divider()
                    rotationRow
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    @ViewBuilder
    private var resetAccessory: some View {
        if isTransformActive {
            Button(action: resetTransform) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(Text("Reset scale, translate, and rotation"))
            .accessibilityLabel(Text("Reset transform"))
            .transition(.opacity)
        }
    }

    private var scaleRow: some View {
        SettingRow(
            icon: "arrow.up.left.and.arrow.down.right",
            iconColor: .teal,
            title: "Scale",
            info: "Scales the rendered page around its center."
        ) {
            HStack(spacing: 4) {
                Slider(
                    value: configDoubleBinding(
                        \.transformScale,
                        epsilon: 0.001,
                        clamp: HTMLConfig.clampedTransformScale
                    ),
                    in: HTMLConfig.minTransformScale...HTMLConfig.maxTransformScale
                )
                .controlSize(.small)
                .frame(width: 96)
                .accessibilityLabel(Text("Scale"))

                Text(verbatim: String(format: "%.0f%%", config.transformScale * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }

    /// Two stacked sliders — X and Y in CSS pixels — sharing one row so
    /// translate stays a single conceptual control. The slider uses an
    /// epsilon-guarded binding (drags emit many near-duplicate values); the
    /// text field bypasses the epsilon so typing `100` over a current `99.6`
    /// commits cleanly instead of snapping back.
    private var translateRow: some View {
        SettingRow(
            icon: "arrow.up.and.down.and.arrow.left.and.right",
            iconColor: .purple,
            title: "Translate",
            info: "Offsets the rendered page horizontally (X) and vertically (Y) in CSS pixels."
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                translateAxisSlider(
                    axisLabel: "X",
                    sliderValue: configDoubleBinding(
                        \.transformTranslateX,
                        epsilon: 0.5,
                        clamp: HTMLConfig.clampedTransformTranslate
                    ),
                    fieldValue: configExactDoubleBinding(
                        \.transformTranslateX,
                        clamp: HTMLConfig.clampedTransformTranslate
                    ),
                    accessibilityLabel: "Translate X"
                )
                translateAxisSlider(
                    axisLabel: "Y",
                    sliderValue: configDoubleBinding(
                        \.transformTranslateY,
                        epsilon: 0.5,
                        clamp: HTMLConfig.clampedTransformTranslate
                    ),
                    fieldValue: configExactDoubleBinding(
                        \.transformTranslateY,
                        clamp: HTMLConfig.clampedTransformTranslate
                    ),
                    accessibilityLabel: "Translate Y"
                )
            }
        }
    }

    @ViewBuilder
    private func translateAxisSlider(
        axisLabel: String,
        sliderValue: Binding<Double>,
        fieldValue: Binding<Double>,
        accessibilityLabel: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: axisLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Slider(
                value: sliderValue,
                in: -HTMLConfig.maxTransformTranslate...HTMLConfig.maxTransformTranslate
            )
            .controlSize(.small)
            .frame(width: 96)
            .accessibilityLabel(Text(accessibilityLabel))

            TextField(
                "",
                value: fieldValue,
                format: .number.precision(.fractionLength(0))
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 56)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(Text("Type a value in CSS pixels."))
        }
    }

    /// Rotation in degrees. `±180` covers everything; we keep the slider
    /// continuous so animation-style "tilt the canvas" use cases feel
    /// responsive instead of stepped.
    private var rotationRow: some View {
        SettingRow(
            icon: "rotate.right",
            iconColor: .pink,
            title: "Rotation",
            info: "Rotates the rendered page around its center."
        ) {
            HStack(spacing: 4) {
                Slider(
                    value: configDoubleBinding(
                        \.transformRotationDegrees,
                        epsilon: 0.1,
                        clamp: HTMLConfig.clampedTransformRotation
                    ),
                    in: -180...180
                )
                .controlSize(.small)
                .frame(width: 78)
                .accessibilityLabel(Text("Rotation"))

                Text(verbatim: String(format: "%.0f°", config.transformRotationDegrees))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }

    private var isTransformActive: Bool {
        abs(config.transformScale - 1.0) > 0.001
            || abs(config.transformTranslateX) > 0.5
            || abs(config.transformTranslateY) > 0.5
            || abs(config.transformRotationDegrees) > 0.1
    }

    private func resetTransform() {
        guard isTransformActive else { return }
        var next = config
        next.transformScale = 1.0
        next.transformTranslateX = 0
        next.transformTranslateY = 0
        next.transformRotationDegrees = 0
        config = next
        screenManager.updateHTMLConfig(next, for: screen)
    }

    // MARK: - Bindings

    private func configDoubleBinding(
        _ keyPath: WritableKeyPath<HTMLConfig, Double>,
        epsilon: Double,
        clamp: @escaping (Double) -> Double
    ) -> Binding<Double> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { rawValue in
                let newValue = clamp(rawValue)
                guard abs(config[keyPath: keyPath] - newValue) > epsilon else { return }
                applyConfigChange(keyPath, value: newValue)
            }
        )
    }

    /// Identity-guarded but epsilon-free — text-field entries near the current
    /// rounded display value must commit instead of being filtered out.
    private func configExactDoubleBinding(
        _ keyPath: WritableKeyPath<HTMLConfig, Double>,
        clamp: @escaping (Double) -> Double
    ) -> Binding<Double> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { rawValue in
                let newValue = clamp(rawValue)
                guard config[keyPath: keyPath] != newValue else { return }
                applyConfigChange(keyPath, value: newValue)
            }
        )
    }

    private func applyConfigChange<Value: Equatable>(
        _ keyPath: WritableKeyPath<HTMLConfig, Value>,
        value: Value
    ) {
        var next = config
        next[keyPath: keyPath] = value
        config = next
        screenManager.updateHTMLConfig(next, for: screen)
    }
}
