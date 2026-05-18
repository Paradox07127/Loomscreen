import LiveWallpaperCore
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OnboardingStepFirstWallpaper: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureCatalog) private var featureCatalog
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

    /// True when the WPE entry point is both feature-enabled (Pro) and a
    /// Steam folder was detected on disk. Lite never reaches this state,
    /// so the Video card stays "featured" in its absence.
    private var wpeFeaturable: Bool {
        featureCatalog.isEnabled(.wpeImport) && wpeFolderExists
    }
    /// Stage machine for the picker flow. Single-screen environments skip
    /// `.screenSelection` entirely; video / HTML pickers route through
    /// `.livePreview` so the user can confirm before applying.
    @State private var stage: OnboardingPickerStage = .sourcePicker
    @State private var selectedScreenIDs: Set<CGDirectDisplayID> = []
    @State private var previewController = InspectorPreviewController()
    /// Inline error displayed below the source picker when a step fails (Aerial
    /// access denied / WPE import failed / Workshop returned nothing). The
    /// failure path no longer auto-advances — the user retries or hits Skip.
    @State private var inlineError: String?
    /// Set to true when at least one screen received a `.wpeImportDidComplete`
    /// notification while the Workshop gallery sheet was open. The sheet
    /// `onDismiss` callback only advances when this is true (audit P0-C).
    @State private var workshopAppliedAny: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 32)

            VStack(spacing: 8) {
                Text(verbatim: headerTitle)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)

                Text(verbatim: headerSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer().frame(height: 24)

            stageContent
                .padding(.horizontal, stageHorizontalPadding)
                .animation(.snappy(duration: 0.22), value: stage)

            Spacer()
        }
        .onAppear { configureInitialStage() }
        .onDisappear { previewController.cleanup() }
        #if !LITE_BUILD
        .sheet(isPresented: $showWorkshopGallery, onDismiss: handleWorkshopGalleryDismiss) {
            WorkshopGalleryView(screens: workshopGalleryTargetScreens)
                .environment(screenManager)
        }
        #endif
        .sheet(isPresented: $showHTMLSheet) {
            HTMLPickerSheet(
                onCancel: { showHTMLSheet = false },
                onConfirm: { source in applyHTML(source) }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeImportDidComplete)) { _ in
            if showWorkshopGallery {
                workshopAppliedAny = true
            }
        }
    }

    private var headerTitle: String {
        switch stage {
        case .screenSelection:
            return String(
                localized: "onboarding.header.screen_selection.title",
                defaultValue: "Apply To Which Displays?",
                comment: "Onboarding header shown while choosing target displays."
            )
        case .sourcePicker:
            return String(
                localized: "onboarding.header.source_picker.title",
                defaultValue: "Pick Your First Wallpaper",
                comment: "Onboarding header shown while choosing the wallpaper source."
            )
        case .livePreview:
            return String(
                localized: "onboarding.header.live_preview.title",
                defaultValue: "Looks Good?",
                comment: "Onboarding header shown while confirming the live preview."
            )
        }
    }

    private var headerSubtitle: String {
        switch stage {
        case .screenSelection:
            let count = screenManager.screens.count
            return String(
                localized: "onboarding.header.screen_selection.subtitle",
                defaultValue: "You can always tweak each display individually later. (\(count) displays detected)",
                comment: "Onboarding subtitle on display selection screen; %lld is the detected display count."
            )
        case .sourcePicker:
            return String(
                localized: "onboarding.header.source_picker.subtitle",
                defaultValue: "You can always add more later from the menu bar.",
                comment: "Onboarding subtitle on source picker screen."
            )
        case .livePreview:
            let count = selectedScreenIDs.count
            return String(
                localized: "onboarding.header.live_preview.subtitle",
                defaultValue: "Confirm to apply to \(count) display\(count == 1 ? "" : "s").",
                comment: "Onboarding subtitle in preview stage; %lld is selected display count. Translators: please use a plural-aware phrase for your locale."
            )
        }
    }

    private var stageHorizontalPadding: CGFloat {
        stage.isScreenSelection ? 24 : 36
    }

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .screenSelection:
            screenSelectionView
        case .sourcePicker:
            sourcePickerView
        case .livePreview(let draft):
            livePreviewView(for: draft)
        }
    }

    @ViewBuilder
    private var screenSelectionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(screenManager.screens, id: \.id) { screen in
                    ScreenThumbnailCard(
                        screen: screen,
                        isSelected: selectedScreenIDs.contains(screen.id)
                    ) {
                        toggleScreenSelection(screen.id)
                    }
                }
            }

            HStack {
                Button("Select All") {
                    selectedScreenIDs = Set(screenManager.screens.map(\.id))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedScreenIDs.count == screenManager.screens.count)

                Spacer()

                Button("Continue") {
                    withAnimation(reduceMotion ? nil : .default) { stage = .sourcePicker }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedScreenIDs.isEmpty)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var sourcePickerView: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("From your Mac")
            VStack(spacing: 8) {
                OnboardingOptionCard(
                    icon: "film",
                    iconTint: .blue,
                    title: "Choose Your Video",
                    subtitle: "Pick an MP4 or MOV from your Mac.",
                    isFeatured: !wpeFeaturable,
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

            if featureCatalog.isEnabled(.wpeImport) {
                sectionHeader("From Steam")
                OnboardingOptionCard(
                    icon: "cube.transparent",
                    iconTint: .orange,
                    title: wpeFolderExists ? "Browse Workshop Library" : "Apply from Wallpaper Engine",
                    subtitle: wpeFolderExists
                        ? "We found your Steam folder. Browse Video, Web, and compatible Scene projects."
                        : "Use a Steam Workshop project folder. Scene support varies.",
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
            }

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
            .keyboardShortcut(featureCatalog.isEnabled(.wpeImport) ? "4" : "3", modifiers: [])

            OnboardingOptionCard(
                icon: "arrow.right.circle",
                iconTint: .secondary,
                title: "Skip for Now",
                subtitle: "I'll set this up later from the settings.",
                isFeatured: false,
                isLoading: false,
                action: skip
            )
            .keyboardShortcut(featureCatalog.isEnabled(.wpeImport) ? "5" : "4", modifiers: [])
            .padding(.top, 4)

            if let inlineError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(verbatim: inlineError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: inlineError != nil)
    }

    @ViewBuilder
    private func livePreviewView(for draft: SourceDraft) -> some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)

                switch draft {
                case .video:
                    if let player = previewController.player {
                        CustomVideoPlayer(player: player, fitMode: .aspectFill)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        ProgressView().controlSize(.regular)
                    }
                case .html:
                    VStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 64))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text("Web Preview Not Available")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("The web wallpaper renders after you confirm.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .frame(maxHeight: 320)

            HStack(spacing: 12) {
                Button("Pick Different Source") {
                    previewController.cleanup()
                    withAnimation(reduceMotion ? nil : .default) { stage = .sourcePicker }
                }
                .keyboardShortcut(.cancelAction)

                Button("Set as Wallpaper") {
                    confirmAndApply(draft: draft)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            if case .video(let url, _) = draft {
                previewController.startPlaybackPreview(from: url, syncTo: nil)
            }
        }
    }

    private func toggleScreenSelection(_ id: CGDirectDisplayID) {
        if selectedScreenIDs.contains(id) {
            guard selectedScreenIDs.count > 1 else { return }
            selectedScreenIDs.remove(id)
        } else {
            selectedScreenIDs.insert(id)
        }
    }

    private func configureInitialStage() {
        detectWPELibrary()
        if screenManager.screens.count > 1 {
            selectedScreenIDs = Set(screenManager.screens.map(\.id))
            stage = .screenSelection
        } else if let only = screenManager.screens.first {
            selectedScreenIDs = [only.id]
            stage = .sourcePicker
        }
    }

    private var workshopGalleryTargetScreens: [Screen] {
        let selected = screenManager.screens.filter { selectedScreenIDs.contains($0.id) }
        if !selected.isEmpty { return selected }
        return Array(screenManager.screens.prefix(1))
    }

    private func confirmAndApply(draft: SourceDraft) {
        let targets = screenManager.screens.filter { selectedScreenIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        previewController.cleanup()

        switch draft {
        case .video(let url, let bookmark):
            for screen in targets {
                screenManager.setVideo(url: url, bookmarkData: bookmark, for: screen)
            }
        case .html(let source):
            for screen in targets {
                screenManager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
            }
        }
        nextStep()
    }

    @ViewBuilder
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
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
        inlineError = nil
        isRequestingAerials = true
        Task {
            let granted = await AppleAerialsLibrary.shared.requestAccess()
            isRequestingAerials = false
            if granted {
                NotificationCenter.default.post(name: .openAppleAerials, object: nil)
                nextStep()
            } else {
                inlineError = String(
                    localized: "Apple Aerials access was denied. Grant access in System Settings → Privacy & Security, or pick another source.",
                    defaultValue: "Apple Aerials access was denied. Grant access in System Settings → Privacy & Security, or pick another source.",
                    comment: "Inline error shown in onboarding when the user denies Apple Aerials access."
                )
            }
        }
    }

    private func chooseVideoFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
        panel.prompt = L10n.Panel.preview

        let response = panel.runModal()
        guard response == .OK, let url = panel.url,
              let bookmark = ResourceUtilities.createVideoBookmark(for: url) else { return }
        inlineError = nil
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        withAnimation(reduceMotion ? nil : .default) { stage = .livePreview(.video(url, bookmark)) }
    }

    private func applyHTML(_ source: HTMLSource) {
        showHTMLSheet = false
        inlineError = nil
        withAnimation(reduceMotion ? nil : .default) { stage = .livePreview(.html(source)) }
    }

    private func chooseWPEFolder() {
        #if LITE_BUILD
        return
        #else
        guard let url = WPEFolderPicker.chooseImportFolder() else { return }

        let targets = screenManager.screens.filter { selectedScreenIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        inlineError = nil
        Task { @MainActor in
            var appliedCount = 0
            var lastFailureReason: String?
            for screen in targets {
                let outcome = await screenManager.importWallpaperEngineProject(at: url, for: screen)
                switch outcome {
                case .applied:
                    appliedCount += 1
                case .unsupported:
                    lastFailureReason = String(
                        localized: "This Wallpaper Engine project type isn't supported yet. Try a Video or Web variant.",
                        defaultValue: "This Wallpaper Engine project type isn't supported yet. Try a Video or Web variant.",
                        comment: "Inline error shown in onboarding when a WPE project type is unsupported."
                    )
                case .rejected(let reason):
                    lastFailureReason = reason
                }
            }
            if appliedCount > 0 {
                nextStep()
            } else {
                inlineError = lastFailureReason ?? String(
                    localized: "Couldn't apply that Wallpaper Engine project. Pick a different folder or skip this step.",
                    defaultValue: "Couldn't apply that Wallpaper Engine project. Pick a different folder or skip this step.",
                    comment: "Inline error shown in onboarding when no WPE display was applied."
                )
            }
        }
        #endif
    }

    private func handleWorkshopGalleryDismiss() {
        defer { workshopAppliedAny = false }
        if workshopAppliedAny {
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

    @State private var selectedKind: HTMLSourceKind = .url
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
                        .accessibilityHidden(true)
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

private struct OnboardingOptionCard: View {
    let icon: String
    let iconTint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
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
        .accessibilityLabel(
            isFeatured
                ? Text("Recommended: \(Text(title))", comment: "Onboarding option a11y label when the option is recommended; %@ is the option title.")
                : Text(title)
        )
        .accessibilityHint(Text(subtitle))
    }
}

extension Notification.Name {
    static let openAppleAerials = Notification.Name("OpenAppleAerials")
}

// MARK: - Picker stage machine

/// Tracks the current step of the onboarding picker. The associated value on
/// `.livePreview` lets us defer applying until the user confirms.
private enum OnboardingPickerStage: Equatable {
    case screenSelection
    case sourcePicker
    case livePreview(SourceDraft)

    var isScreenSelection: Bool {
        if case .screenSelection = self { return true }
        return false
    }
}

/// Captures enough state to apply a wallpaper after the user confirms in
/// the live-preview stage. WPE import / Apple Aerials skip the preview path.
private enum SourceDraft: Equatable {
    case video(URL, Data)
    case html(HTMLSource)
}

private struct ScreenThumbnailCard: View {
    let screen: Screen
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "display")
                    .font(.system(size: 32))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 2) {
                    Text(verbatim: screen.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(verbatim: "\(Int(screen.frame.width)) × \(Int(screen.frame.height))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .accessibilityLabel(Text("\(screen.name), \(Int(screen.frame.width)) by \(Int(screen.frame.height)) pixels"))
        .accessibilityValue(isSelected
            ? Text("Selected", comment: "A11y value for screen thumbnail when the screen is currently selected.")
            : Text("Not selected", comment: "A11y value for screen thumbnail when the screen is not selected."))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text("Toggles whether the first wallpaper applies to this display"))
    }
}
