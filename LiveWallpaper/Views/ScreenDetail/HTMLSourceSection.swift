import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Picker and options for URL, file, or folder-backed HTML wallpapers.
struct HTMLSourceSection: View {
    var screen: Screen
    @Binding var source: HTMLSource?
    @Binding var config: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager
    @State private var trustStore = TrustedHostStore.shared

    @State private var selectedKind: HTMLSourceKind = .url
    @State private var urlInput: String = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer(minLength: 0)
                    HTMLSourceKindPicker(selection: $selectedKind)
                        .frame(maxWidth: 280)
                    Spacer(minLength: 0)
                }

                sourcePane
                    .animation(.snappy(duration: 0.18), value: selectedKind)

                if let source, source.isInsecureURL {
                    insecureURLBanner
                }
                if let source { trustBanner(for: source) }
                if let source { multiInstanceBanner(for: source) }
            }
            .padding(14)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .onAppear { scheduleBindingSync() }
        .onChange(of: source) { _, _ in
            scheduleBindingSync()
        }
    }

    // MARK: - Source Pane

    @ViewBuilder
    private var sourcePane: some View {
        switch selectedKind {
        case .url:
            urlField
        case .file:
            filePickerRow
        case .folder:
            folderPickerRow
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("https://example.com or example.com", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitURL() }

                Button("Use") { commitURL() }
                    .adaptiveGlassButton(.prominent)
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Web pages, Shadertoy, CodePen demos, or any URL.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var filePickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                summaryLine(
                    icon: "doc.richtext",
                    text: source.flatMap(fileSummary).map { Text(verbatim: $0) } ?? Text("No file chosen")
                )
                Spacer()
                Button("Choose…") { pickFile() }
                    .buttonStyle(.bordered)
            }
            Text("Pick one .html file. Choose Folder when the page needs sibling JS, CSS, or images.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var folderPickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                summaryLine(
                    icon: "folder",
                    text: source.flatMap(folderSummary).map { Text(verbatim: $0) } ?? Text("No folder chosen")
                )
                Spacer()
                Button("Choose…") { pickFolder() }
                    .buttonStyle(.bordered)
            }
            Text("Pick or drop a folder containing index.html plus any JS, CSS, or images it loads.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var insecureURLBanner: some View {
        Label("This URL uses HTTP. Content cannot be verified — prefer HTTPS when possible.", systemImage: "exclamationmark.shield")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func multiInstanceBanner(for source: HTMLSource) -> some View {
        let others = screenManager.screensRunningSameHTMLSource(as: source, excluding: screen.id)
        if !others.isEmpty {
            let names = others.map(\.name).joined(separator: ", ")
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Same wallpaper is running on \(others.count) other screen\(others.count == 1 ? "" : "s")")
                        .font(.caption)
                    Text("Audio is locked to the first screen. GPU cost scales with screen count — consider a different source per display.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(Text("Also active on: \(names)"))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func trustBanner(for source: HTMLSource) -> some View {
        let trust = HTMLTrust.evaluate(source: source, trustedOrigins: trustStore.originSet)
        switch trust {
        case .localContent:
            EmptyView()
        case .trustedRemote(let origin):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("Trusted — JavaScript runs as configured.")
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Revoke") { trustStore.revoke(origin) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(Text("Remove \(origin.displayName) from trusted origins"))
                    .fixedSize()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        case .untrustedRemote(let origin):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("JavaScript disabled for untrusted source.")
                        .font(.caption)
                        .lineLimit(2)
                    Text(trustMessage(for: origin))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if origin.isSecure {
                    Button("Trust this origin") {
                        _ = trustStore.trust(origin)
                        screenManager.setHTMLWallpaper(source: source, config: config, forceReload: true, for: screen)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .help(Text("Allow \(origin.displayName) to run JavaScript"))
                    .fixedSize()
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func trustMessage(for origin: TrustedHTMLOrigin) -> String {
        if origin.isSecure {
            return "\(origin.displayName) can run scripts only after you trust this exact origin."
        }
        return "HTTP origins cannot be trusted for JavaScript. Use HTTPS when possible."
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

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedHTMLContentTypes
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let source = ResourceUtilities.htmlSourceFromPickedFile(url) else { return }
        screenManager.setHTMLWallpaper(source: source, config: config, for: screen)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        guard let bookmark = ResourceUtilities.createBookmark(for: folderURL) else { return }
        let indexFileName = inferIndexFileName(in: folderURL)
        screenManager.setHTMLWallpaper(
            source: .folder(bookmarkData: bookmark, indexFileName: indexFileName),
            config: config,
            for: screen
        )
    }

    private func commitConfig() {
        screenManager.updateHTMLConfig(config, for: screen)
    }

    // MARK: - Helpers

    private func syncFromBinding() {
        guard let source else {
            if selectedKind != .url { selectedKind = .url }
            if !urlInput.isEmpty { urlInput = "" }
            return
        }
        switch source {
        case .url(let url):
            if selectedKind != .url { selectedKind = .url }
            if urlInput != url.absoluteString { urlInput = url.absoluteString }
        case .file:
            if selectedKind != .file { selectedKind = .file }
        case .folder:
            if selectedKind != .folder { selectedKind = .folder }
        case .inline(let html):
            if selectedKind != .url { selectedKind = .url }
            if urlInput != html { urlInput = html }
        }
    }

    private func fileSummary(_ source: HTMLSource) -> String? {
        guard case .file = source else { return nil }
        return source.displayName
    }

    private func folderSummary(_ source: HTMLSource) -> String? {
        guard case .folder = source else { return nil }
        return source.displayName
    }

    private func inferIndexFileName(in folder: URL) -> String {
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
        for candidate in ["index.html", "index.htm"] {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
           let firstHTML = entries.first(where: { $0.lowercased().hasSuffix(".html") }) {
            return firstHTML
        }
        return "index.html"
    }
}

/// HTML-side analog of the Video inspector groups: lives in the right-hand
/// inspector column, slots in directly under `CommonPlaybackInspector` so
/// "Playback & Privacy" → "HTML Options" form the same vertical rhythm
/// Video's panel has with Particles / Color & Filters / Environment.
///
/// The source picker (URL / File / Folder) stays in the main panel on the
/// left — only the *option* toggles move here, mirroring how Video keeps
/// its display-mode picker on the left and inspector toggles on the right.
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
            Toggle("", isOn: Binding(
                get: { config.allowJavaScript },
                set: { newValue in
                    config.allowJavaScript = newValue
                    commitConfig()
                }
            ))
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
            Toggle("", isOn: Binding(
                get: { config.allowMouseInteraction },
                set: { newValue in
                    config.allowMouseInteraction = newValue
                    commitConfig()
                }
            ))
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
            info: "Maps window.innerWidth to physical pixels (Wallpaper Engine compatibility). Auto-enabled for folders containing project.json."
        ) {
            Toggle("", isOn: Binding(
                get: { config.physicalPixelLayout },
                set: { newValue in
                    config.physicalPixelLayout = newValue
                    commitConfig()
                }
            ))
            .labelsHidden()
            .accessibilityLabel(Text("Physical-pixel layout"))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    // MARK: - Auto-refresh + Transform rows

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
            Picker("", selection: Binding(
                get: { config.refreshIntervalSeconds },
                set: { newValue in
                    let clamped = HTMLConfig.clampedRefreshInterval(newValue)
                    guard config.refreshIntervalSeconds != clamped else { return }
                    config.refreshIntervalSeconds = clamped
                    commitConfig()
                }
            )) {
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

    /// Custom CSS row — the editor itself opens in a popover instead of
    /// expanding inline so the inspector list stays compact while the user
    /// still gets a comfortable multi-line editing surface.
    private var customCSSRow: some View {
        SettingRow(
            icon: "paintbrush",
            iconColor: .pink,
            title: "Custom CSS"
        ) {
            Button {
                customCSSPresented = true
            } label: {
                Text("Edit…")
            }
            .controlSize(.small)
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
                    config.customCSS = draftCustomCSS.isEmpty ? nil : draftCustomCSS
                    commitConfig()
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

    // MARK: - Helpers

    private func commitConfig() {
        screenManager.updateHTMLConfig(config, for: screen)
    }

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

/// Transform inspector — Scale / Translate / Rotation live in their own
/// GroupBox sibling to HTMLOptionsInspector so the toggle-style options
/// (JavaScript, mouse interaction, refresh interval, custom CSS) stay
/// visually distinct from the continuous geometry controls.
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
                isExpanded: $isExpanded
            ) {
                VStack(spacing: 8) {
                    scaleRow
                    Divider()
                    translateRow
                    Divider()
                    rotationRow
                    Divider()
                    resetButtonRow
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    /// Scale row: a single slider plus a numeric readout.
    private var scaleRow: some View {
        SettingRow(
            icon: "arrow.up.left.and.arrow.down.right",
            iconColor: .teal,
            title: "Scale",
            info: "Scales the rendered page around its center."
        ) {
            HStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { config.transformScale },
                        set: { newValue in
                            let clamped = HTMLConfig.clampedTransformScale(newValue)
                            guard abs(config.transformScale - clamped) > 0.001 else { return }
                            config.transformScale = clamped
                            commitConfig()
                        }
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

    /// Dedicated reset row at the bottom of the Transform group. Mirrors the
    /// "Reset Color & Filters" pattern in ColorAdjustmentsView so the
    /// destructive action sits visually apart from the value controls.
    private var resetButtonRow: some View {
        HStack {
            Spacer()
            Button(action: resetTransform) {
                Label("Reset Transform", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
            .disabled(!isTransformActive)
            .help(Text("Reset scale, translate, and rotation"))
            .accessibilityLabel(Text("Reset transform"))
            Spacer()
        }
    }

    /// Two stacked sliders — X and Y in CSS pixels — sharing one row so
    /// translate stays a single conceptual control. A draggable slider beats
    /// a stepper for "find a good position" tasks; the numeric readout still
    /// shows the exact pixel value for fine adjustments.
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
                    value: Binding(
                        get: { config.transformTranslateX },
                        set: { newValue in
                            let clamped = HTMLConfig.clampedTransformTranslate(newValue)
                            guard abs(config.transformTranslateX - clamped) > 0.5 else { return }
                            config.transformTranslateX = clamped
                            commitConfig()
                        }
                    ),
                    accessibilityLabel: "Translate X"
                )
                translateAxisSlider(
                    axisLabel: "Y",
                    value: Binding(
                        get: { config.transformTranslateY },
                        set: { newValue in
                            let clamped = HTMLConfig.clampedTransformTranslate(newValue)
                            guard abs(config.transformTranslateY - clamped) > 0.5 else { return }
                            config.transformTranslateY = clamped
                            commitConfig()
                        }
                    ),
                    accessibilityLabel: "Translate Y"
                )
            }
        }
    }

    @ViewBuilder
    private func translateAxisSlider(
        axisLabel: String,
        value: Binding<Double>,
        accessibilityLabel: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: axisLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Slider(
                value: value,
                in: -HTMLConfig.maxTransformTranslate...HTMLConfig.maxTransformTranslate
            )
            .controlSize(.small)
            .frame(width: 96)
            .accessibilityLabel(Text(accessibilityLabel))

            TextField(
                "",
                value: value,
                format: .number.precision(.fractionLength(0))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 42)
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
                    value: Binding(
                        get: { config.transformRotationDegrees },
                        set: { newValue in
                            let clamped = HTMLConfig.clampedTransformRotation(newValue)
                            guard abs(config.transformRotationDegrees - clamped) > 0.1 else { return }
                            config.transformRotationDegrees = clamped
                            commitConfig()
                        }
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
        config.transformScale = 1.0
        config.transformTranslateX = 0
        config.transformTranslateY = 0
        config.transformRotationDegrees = 0
        commitConfig()
    }

    private func commitConfig() {
        screenManager.updateHTMLConfig(config, for: screen)
    }
}
