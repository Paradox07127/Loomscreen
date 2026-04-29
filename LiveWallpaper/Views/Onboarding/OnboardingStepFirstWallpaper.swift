import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OnboardingStepFirstWallpaper: View {
    let nextStep: () -> Void
    let skip: () -> Void

    @Environment(ScreenManager.self) private var screenManager
    @State private var isRequestingAerials = false
    @State private var showHTMLSheet = false
    @State private var showWorkshopGallery = false
    /// Auto-detected on appear. Drives the WPE entry-point: if the user
    /// already has a Wallpaper Engine library, jump straight to the
    /// Workshop Gallery instead of presenting a single-folder picker.
    @State private var wpeFolderExists = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 32)

            VStack(spacing: 8) {
                Text("Pick Your First Wallpaper")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)

                Text("You can always add more later from the menu bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 24)

            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("From your Mac")
                VStack(spacing: 8) {
                    OnboardingOptionCard(
                        icon: "film",
                        iconTint: .blue,
                        title: "Choose Your Video",
                        subtitle: "Pick an MP4 or MOV from your Mac.",
                        isFeatured: !wpeFolderExists,
                        isLoading: false,
                        action: chooseVideoFile
                    )
                    .keyboardShortcut("1", modifiers: [])

                    OnboardingOptionCard(
                        icon: "globe",
                        iconTint: .green,
                        title: "Add a Web Page",
                        subtitle: "Use a website or local HTML as a live wallpaper.",
                        isFeatured: false,
                        isLoading: false,
                        action: { showHTMLSheet = true }
                    )
                    .keyboardShortcut("2", modifiers: [])
                }

                sectionHeader("From Steam")
                OnboardingOptionCard(
                    icon: "cube.transparent",
                    iconTint: .orange,
                    title: wpeFolderExists ? "Browse Workshop Library" : "Import from Wallpaper Engine",
                    subtitle: wpeFolderExists
                        ? "We found your Steam folder. Browse Video / Web projects instantly."
                        : "Use your Steam Workshop wallpapers. Scene types are preview-only.",
                    isFeatured: wpeFolderExists,
                    isLoading: false,
                    action: {
                        if wpeFolderExists {
                            showWorkshopGallery = true
                        } else {
                            chooseWPEFolder()
                        }
                    }
                )
                .keyboardShortcut("3", modifiers: [])

                sectionHeader("Built-in")
                OnboardingOptionCard(
                    icon: "sparkles.tv",
                    iconTint: .secondary,
                    title: "Use Apple Aerials",
                    subtitle: "Browse Apple's downloaded aerial wallpapers.",
                    isFeatured: false,
                    isLoading: isRequestingAerials,
                    action: chooseAerials
                )
                .keyboardShortcut("4", modifiers: [])

                OnboardingOptionCard(
                    icon: "arrow.right.circle",
                    iconTint: .secondary,
                    title: "Skip for Now",
                    subtitle: "I'll set this up later from the settings.",
                    isFeatured: false,
                    isLoading: false,
                    action: skip
                )
                .keyboardShortcut("5", modifiers: [])
                .padding(.top, 4)
            }
            .padding(.horizontal, 36)

            Spacer()
        }
        .onAppear { detectWPELibrary() }
        .sheet(isPresented: $showWorkshopGallery, onDismiss: nextStep) {
            WorkshopGalleryView()
                .environment(screenManager)
        }
        .sheet(isPresented: $showHTMLSheet) {
            HTMLPickerSheet(
                onCancel: { showHTMLSheet = false },
                onConfirm: { source in applyHTML(source) }
            )
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }

    private func detectWPELibrary() {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }
        let lwDir = docs.appendingPathComponent("Live Wallpapers")
        wpeFolderExists = FileManager.default.fileExists(atPath: lwDir.path)
    }

    private func chooseAerials() {
        guard !isRequestingAerials else { return }
        isRequestingAerials = true
        Task {
            let granted = await AppleAerialsLibrary.shared.requestAccess()
            isRequestingAerials = false
            if granted {
                NotificationCenter.default.post(name: .openAppleAerials, object: nil)
            }
            nextStep()
        }
    }

    private func chooseVideoFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie, .avi]
        panel.prompt = "Use Wallpaper"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        if let screen = screenManager.screens.first,
           let bookmark = ResourceUtilities.createBookmark(for: url) {
            screenManager.setVideo(url: url, bookmarkData: bookmark, for: screen)
            SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        }
        nextStep()
    }

    private func applyHTML(_ source: HTMLSource) {
        if let screen = screenManager.screens.first {
            screenManager.setHTMLWallpaper(source: source, for: screen)
        }
        showHTMLSheet = false
        nextStep()
    }

    private func chooseWPEFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Project"

        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let lwDir = docs.appendingPathComponent("Live Wallpapers")
            if FileManager.default.fileExists(atPath: lwDir.path) {
                panel.directoryURL = lwDir
            }
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let screen = screenManager.screens.first {
            Task { @MainActor in
                await screenManager.importWallpaperEngineProject(at: url, for: screen)
                nextStep()
            }
        } else {
            nextStep()
        }
    }
}

// MARK: - HTML Picker Sheet

/// Three-tab sheet that lets first-run users start with any HTML source kind.
/// File/Folder go through `NSOpenPanel` so the resulting bookmark is
/// security-scoped — the same machinery the inspector uses.
private struct HTMLPickerSheet: View {
    let onCancel: () -> Void
    let onConfirm: (HTMLSource) -> Void

    @State private var selectedKind: PickerKind = .url
    @State private var urlInput: String = ""
    /// The source produced by `pickFile` — usually a `.folder` upgrade so
    /// sibling assets (CSS/JS/images) keep resolving across launches; a
    /// `.file` fallback when the parent grant is denied.
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
                    .font(.system(size: 16, weight: .semibold))
                Text("Use a website, a single .html file, or a full folder of assets.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Picker("Source", selection: $selectedKind) {
                ForEach(PickerKind.allCases) { kind in
                    Label(kind.label, systemImage: kind.icon).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
                    Text(pickedFileName.isEmpty ? "No file chosen" : pickedFileName)
                        .font(.system(size: 12, design: .monospaced))
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
                    Text(pickedFolderName.isEmpty ? "No folder chosen" : pickedFolderName)
                        .font(.system(size: 12, design: .monospaced))
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

    // MARK: - Commit

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

    // MARK: - File / Folder Pickers

    private func pickFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.html]
        panel.prompt = "Use Wallpaper"
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
        panel.prompt = "Use Wallpaper"
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

private enum PickerKind: String, CaseIterable, Identifiable {
    case url, file, folder
    var id: String { rawValue }
    var label: String {
        switch self {
        case .url: return "URL"
        case .file: return "File"
        case .folder: return "Folder"
        }
    }
    var icon: String {
        switch self {
        case .url: return "globe"
        case .file: return "doc.richtext"
        case .folder: return "folder"
        }
    }
}

private struct OnboardingOptionCard: View {
    let icon: String
    let iconTint: Color
    let title: String
    let subtitle: String
    let isFeatured: Bool
    let isLoading: Bool
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { isHovering || isFocused }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(iconTint)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if isFeatured {
                    Text("Recommended")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isActive && !reduceMotion ? 1.02 : 1.0)
        .shadow(
            color: .black.opacity(isActive ? 0.18 : (isFeatured ? 0.06 : 0)),
            radius: isActive ? 8 : 4,
            y: isActive ? 4 : 2
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isHovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isFocused)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isFeatured ? "Recommended: \(title)" : title)
        .accessibilityHint(subtitle)
    }
}

extension Notification.Name {
    static let openAppleAerials = Notification.Name("OpenAppleAerials")
}
