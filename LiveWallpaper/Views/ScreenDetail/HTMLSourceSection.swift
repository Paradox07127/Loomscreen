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
    @State private var customCSSExpanded: Bool = false
    @State private var draftCustomCSS: String = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Web / HTML Wallpaper", systemImage: "globe")
                    .font(.headline)

                HTMLSourceKindPicker(selection: $selectedKind)

                sourcePane
                    .animation(.snappy(duration: 0.18), value: selectedKind)

                if let source, source.isInsecureURL {
                    insecureURLBanner
                }
                if let source { trustBanner(for: source) }
                if let source { multiInstanceBanner(for: source) }

                Divider()

                togglesGrid

                Divider()

                customCSSDisclosure
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
                        // Re-apply with the now-trusted origin so JS turns on.
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

    // MARK: - Toggles

    private var togglesGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("JavaScript", systemImage: "curlybraces")
                Spacer()
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
            HStack {
                Label("Mouse Interaction", systemImage: "cursorarrow.click")
                Spacer()
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
            Text(config.allowMouseInteraction
                 ? "Clicks and scrolls reach the wallpaper. Desktop icons are hidden behind the page while this is on."
                 : "Clicks fall through to the desktop, so Finder icons and the Dock stay usable.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // "Mute Audio" / "Block Trackers" moved to CommonPlaybackInspector
            // (Playback & Privacy section) so the controls share a stable
            // physical position with the equivalent video toggles.

            HStack {
                Label("Physical-pixel layout", systemImage: "rectangle.split.2x1")
                Spacer()
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
            Text("Maps window.innerWidth to physical pixels (Wallpaper Engine compatibility). Auto-enabled for folders containing project.json.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Custom CSS

    private var customCSSDisclosure: some View {
        DisclosureGroup(isExpanded: $customCSSExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draftCustomCSS)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 90, maxHeight: 160)
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button("Apply CSS") {
                        config.customCSS = draftCustomCSS.isEmpty ? nil : draftCustomCSS
                        commitConfig()
                    }
                    .buttonStyle(.bordered)
                    .disabled(draftCustomCSS == (config.customCSS ?? ""))
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Custom CSS", systemImage: "paintbrush")
                .font(.subheadline)
        }
        .onAppear { scheduleCustomCSSDraftSync(config.customCSS) }
        .onChange(of: config.customCSS) { _, newValue in
            scheduleCustomCSSDraftSync(newValue)
        }
    }

    // MARK: - Actions

    private func scheduleBindingSync() {
        DispatchQueue.main.async {
            Task { @MainActor in
                syncFromBinding()
            }
        }
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
        // Prefer a folder bookmark so siblings (CSS/JS/images) keep working
        // across launches; falls back to a file-only bookmark when the
        // sandbox refuses the parent grant.
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
