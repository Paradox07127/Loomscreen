import AppKit
import LiveWallpaperCore
import SwiftUI
import UniformTypeIdentifiers

/// Three-tab sheet that lets first-run users start with any HTML source kind.
/// File/Folder go through `NSOpenPanel` so the resulting bookmark is
/// security-scoped — the same machinery the inspector uses. Lifted out of
/// `OnboardingStepFirstWallpaper` so both Pro and Lite picker paths can host
/// the same sheet.
struct HTMLPickerSheet: View {
    let onCancel: () -> Void
    let onConfirm: (HTMLSource) -> Void

    @State private var selectedKind: HTMLSourceKind = .url
    @State private var urlInput: String = ""
    @State private var pickedFileSource: HTMLSource? = nil
    @State private var pickedFileName: String = ""
    @State private var pickedFolderBookmark: Data? = nil
    @State private var pickedFolderIndexFile: String = "index.html"
    @State private var pickedFolderName: String = ""

    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Web / HTML Wallpaper")
                    .font(DesignTokens.Typography.sectionTitle)
                Text("Use a website, a single .html file, or a full folder of assets.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            HTMLSourceKindPicker(selection: $selectedKind)

            sourcePane
                .animation(.snappy(duration: 0.18), value: selectedKind)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Use as Wallpaper", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isURLFieldFocused = true }
    }

    @ViewBuilder
    private var sourcePane: some View {
        switch selectedKind {
        case .url:
            VStack(alignment: .leading, spacing: 6) {
                TextField("example.com or https://…", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($isURLFieldFocused)
                    .onSubmit { commit() }
                Text("HTTPS is added automatically when no scheme is given.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .file:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "doc.richtext")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(pickedFileName.isEmpty ? "No file chosen" : pickedFileName)
                        .font(DesignTokens.Typography.code)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: pickFile)
                        .buttonStyle(.bordered)
                }
                Text("Pick a single .html file. Sibling assets next to the file are accessible.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .folder:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(pickedFolderName.isEmpty ? "No folder chosen" : pickedFolderName)
                        .font(DesignTokens.Typography.code)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: pickFolder)
                        .buttonStyle(.bordered)
                }
                Text("Pick a folder containing index.html plus any JS, CSS, or images it loads.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canCommit: Bool {
        switch selectedKind {
        case .url:    return !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file:   return pickedFileSource != nil
        case .folder: return pickedFolderBookmark != nil
        }
    }

    private func commit() {
        switch selectedKind {
        case .url:
            guard let source = HTMLSource(userInput: urlInput) else { return }
            onConfirm(source)
        case .file:
            guard let source = pickedFileSource else { return }
            onConfirm(source)
        case .folder:
            guard let bookmark = pickedFolderBookmark else { return }
            onConfirm(.folder(bookmarkData: bookmark, indexFileName: pickedFolderIndexFile))
        }
    }

    private func pickFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedHTMLContentTypes
        panel.prompt = L10n.Panel.useWallpaper
        guard panel.runModal() == .OK, let url = panel.url,
              let source = ResourceUtilities.htmlSourceFromPickedFile(url) else { return }
        pickedFileSource = source
        pickedFileName = url.lastPathComponent
    }

    private func pickFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.Panel.useWallpaper
        guard panel.runModal() == .OK, let folderURL = panel.url,
              let bookmark = ResourceUtilities.createBookmark(for: folderURL) else { return }
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        let inferred = ResourceUtilities.inferHTMLIndexFileName(from: entries)
        pickedFolderBookmark = bookmark
        pickedFolderName = folderURL.lastPathComponent
        pickedFolderIndexFile = inferred
    }
}
