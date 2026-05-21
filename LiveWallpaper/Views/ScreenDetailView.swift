import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScreenDetailView: View {
    var screen: Screen
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog

    @State private var draft: ScreenDetailDraftState = .default
    @State private var isLoading: Bool = false
    private var wallpaperSessionSummary: WallpaperSessionSummary {
        screenManager.wallpaperSummary(for: screen)
    }
    private var runtimeError: WallpaperRuntimeError? {
        screenManager.runtimeError(for: screen)
    }

    @ViewBuilder
    private var runtimeErrorBannerView: some View {
        if let runtimeError {
            let activeType = screen.runtimeSession?.wallpaperType ?? draft.selectedWallpaperType
            let canRePick = activeType == .video || activeType == .html
            RuntimeErrorBanner(
                error: runtimeError,
                canRePick: canRePick,
                onRetry: { screenManager.retryRuntimeSession(for: screen) },
                onRePick: rePickRuntimeSource
            )
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var wallpaperTypePicker: some View {
        Picker("Wallpaper Type", selection: wallpaperTypeSelection) {
            ForEach(featureCatalog.capabilities.selectableWallpaperTypes) { type in
                Text(type.titleKey).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text("Wallpaper type"))
        .accessibilityHint(Text("Choose wallpaper type"))
    }

    private var wallpaperTypeToolbar: some View {
        wallpaperTypePicker
    }

    private var wallpaperTypeSelection: Binding<WallpaperType> {
        Binding(
            get: { draft.selectedWallpaperType },
            set: { newType in
                guard draft.selectedWallpaperType != newType else { return }
                draft.selectedWallpaperType = newType
                handleWallpaperTypeSelection(newType)
            }
        )
    }

    private func handleWallpaperTypeSelection(_ newType: WallpaperType) {
        Logger.info("Wallpaper type selected for screen \(screen.id): \(newType.rawValue)", category: .ui)
        switch newType {
        case .video:
            screenManager.switchToVideoWallpaper(for: screen)
        case .html:
            screenManager.switchToHTMLWallpaper(for: screen)
        case .metalShader:
            guard featureCatalog.isEnabled(.metalShader) else { return }
            screenManager.setShaderWallpaper(preset: draft.selectedShaderPreset, for: screen)
        case .scene:
            break
        }
    }

    /// Resolved Wallpaper Engine origin metadata for the active wallpaper, or
    /// nil when the user picked content directly. Recomputed on every body
    /// evaluation so save/import flows propagate without local @State.
    private var wpeOrigin: WPEOrigin? {
        screenManager.getConfiguration(for: screen)?.wpeOrigin
    }

    /// Single source of truth for the four overlapping booleans the rest of
    /// the view used to compute inline (`shouldShowGuideEmptyState`,
    /// `hasConfigurableWallpaperSurface`, `showsInspector`,
    /// `showsHeaderWallpaperActions`). Each was reading the same store /
    /// runtime state and re-deriving partially overlapping conclusions; the
    /// dependencies were hard to audit. Collapsing them into one computed
    /// struct keeps the rules in one place and makes downstream wrappers
    /// trivial three-line passthroughs.
    private struct DerivedViewState {
        var showsGuideEmptyState: Bool
        var hasConfigurableSurface: Bool
        var showsInspector: Bool
        var showsHeaderWallpaperActions: Bool
    }

    private var derivedState: DerivedViewState {
        let config = screenManager.getConfiguration(for: screen)
        let hasRuntimeOrPreview = screen.runtimeSession != nil
            || draft.hasPreviewSource
            || previewController.hasPreviewContent

        let showsGuide: Bool = !isLoading
            && config == nil
            && !hasRuntimeOrPreview
            && draft.selectedWallpaperType == .video

        let hasConfigurable = !showsGuide && (config != nil || hasRuntimeOrPreview)

        let showsInspector: Bool = {
            guard hasConfigurable else { return false }
            switch draft.selectedWallpaperType {
            case .video:
                return config?.wallpaperType == .video && (config?.hasConfiguredVideoSource ?? false)
            case .html:
                return true
            case .metalShader, .scene:
                return false
            }
        }()

        return DerivedViewState(
            showsGuideEmptyState: showsGuide,
            hasConfigurableSurface: hasConfigurable,
            showsInspector: showsInspector,
            showsHeaderWallpaperActions: hasConfigurable
        )
    }

    private var shouldShowGuideEmptyState: Bool { derivedState.showsGuideEmptyState }
    private var hasConfigurableWallpaperSurface: Bool { derivedState.hasConfigurableSurface }
    private var showsInspector: Bool { derivedState.showsInspector }
    private var showsHeaderWallpaperActions: Bool { derivedState.showsHeaderWallpaperActions }

    /// User-facing pickerable error states. Each case carries enough context
    /// to render a meaningful retry / re-pick action instead of a generic
    /// "OK" dismissal — telling someone "Failed to bookmark" without offering
    /// a way out is a dead end.
    private enum DropFailure: Identifiable {
        case invalidDropType(suggestion: WallpaperType)
        case videoFormatUnsupported
        case videoBookmarkFailed
        case htmlBookmarkFailed
        case htmlPickerWrongType

        var id: String {
            switch self {
            case .invalidDropType:        return "invalidDropType"
            case .videoFormatUnsupported: return "videoFormatUnsupported"
            case .videoBookmarkFailed:    return "videoBookmarkFailed"
            case .htmlBookmarkFailed:     return "htmlBookmarkFailed"
            case .htmlPickerWrongType:    return "htmlPickerWrongType"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .invalidDropType:        return "Unsupported file type"
            case .videoFormatUnsupported: return "Video format not supported"
            case .videoBookmarkFailed:    return "Couldn't open video"
            case .htmlBookmarkFailed:     return "Couldn't open HTML resource"
            case .htmlPickerWrongType:    return "Pick an HTML file or folder"
            }
        }

        var message: LocalizedStringKey {
            switch self {
            case .invalidDropType:
                return "Drop a video file, HTML file, or folder to use it as a wallpaper."
            case .videoFormatUnsupported:
                return "Choose an .mp4, .mov, .m4v, or similar video file."
            case .videoBookmarkFailed:
                return "macOS couldn't grant the app secure access to that file. Try a different video, or move the file to a folder you own."
            case .htmlBookmarkFailed:
                return "macOS couldn't grant the app secure access to that resource. Try moving it to a folder you own."
            case .htmlPickerWrongType:
                return "The selection isn't an HTML file or a folder containing an index page."
            }
        }
    }

    @State private var dropFailure: DropFailure?
    @State private var pendingDestructive: PendingDestructive?
    @State private var previewController = InspectorPreviewController()
    @State private var lastPreviewPosterBookmarkData: Data?

    @State private var isDraggingOver = false
    @State private var lockScreenExtracted: Bool = false
    @State private var showBookmarks = false

    @AppStorage("Inspector.EnvironmentExpanded") private var isEnvironmentExpanded = true
    @AppStorage("Inspector.ColorExpanded") private var isColorExpanded = false
    @AppStorage("Inspector.Width") private var inspectorWidth = Double(DesignTokens.Inspector.defaultWidth)
    @State private var liveInspectorWidth: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            screenHeader

            runtimeErrorBannerView

            Divider()

            HStack(spacing: 0) {
                ScreenDetailPreviewArea(
                    screen: screen,
                    draft: $draft,
                    featureCatalog: featureCatalog,
                    previewController: previewController,
                    wpeOrigin: wpeOrigin,
                    isLoading: isLoading,
                    isDraggingOver: isDraggingOver,
                    reduceMotion: reduceMotion,
                    showsGuideEmptyState: shouldShowGuideEmptyState,
                    onChooseVideo: triggerVideoGuideAction,
                    onChooseHTML: triggerHTMLGuideAction,
                    onChooseShader: triggerShaderGuideAction,
                    onChooseScene: triggerSceneGuideAction,
                    onSelectVideoFile: showFilePicker,
                    onStartPreview: setupPreviewPlayer,
                    onPlaybackSpeedChange: { screenManager.updatePlaybackSpeed($0, for: screen) },
                    onFitModeChange: { screenManager.updateFitMode($0, for: screen) }
                )

                if showsInspector {
                    inspectorPanel
                        .overlay(alignment: .leading) {
                            InspectorResizeHandle(
                                width: inspectorPanelWidth,
                                minWidth: DesignTokens.Inspector.minWidth,
                                maxWidth: DesignTokens.Inspector.maxWidth,
                                onPreviewWidthChange: previewInspectorWidth,
                                onCommitWidth: commitInspectorWidth
                            )
                            .offset(x: -InspectorResizeHandle.hitAreaWidth / 2)
                        }
                        .layoutPriority(0)
                }
            }
            .transaction(value: draft.selectedWallpaperType) { $0.animation = nil }
            .transaction(value: liveInspectorWidth) { $0.animation = nil }
        }
        .background(DesignTokens.Colors.pageBackground)
        .toolbar {
            ToolbarItem(placement: .principal) {
                wallpaperTypeToolbar
            }
        }
        .confirmDestructive($pendingDestructive)
        .onAppear { scheduleConfigurationLoad() }
        .onDisappear { cleanupPreviewPlayer() }
        .onChange(of: screen.id) {
            cleanupPreviewPlayer()
            scheduleConfigurationLoad()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            guard let changedID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
                  changedID == screen.id else { return }
            scheduleConfigurationLoad()
        }
        .alert(
            dropFailure.map { Text($0.title) } ?? Text(""),
            isPresented: dropFailurePresented,
            presenting: dropFailure
        ) { failure in
            dropFailureButtons(failure)
        } message: { failure in
            Text(failure.message)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
        } isTargeted: { targeted in
            isDraggingOver = targeted
        }
    }

    private var screenHeader: some View {
        ScreenDetailHeader(
            screen: screen,
            draft: $draft,
            screenManager: screenManager,
            wallpaperSessionSummary: wallpaperSessionSummary,
            reduceMotion: reduceMotion,
            showsHeaderWallpaperActions: showsHeaderWallpaperActions,
            showBookmarks: $showBookmarks,
            onReload: { screenManager.reloadWallpaperForScreen(screen) },
            onApplyToAll: requestApplyToAll,
            onSelectVideo: showFilePicker,
            onClearWallpaper: clearCurrentWallpaper
        )
    }

    @ViewBuilder
    private var inspectorPanel: some View {
        if showsInspector {
            ScreenDetailInspectorPanel(
                screen: screen,
                draft: $draft,
                screenManager: screenManager,
                featureCatalog: featureCatalog,
                reduceMotion: reduceMotion,
                inspectorPanelWidth: inspectorPanelWidth,
                isEnvironmentExpanded: $isEnvironmentExpanded,
                isColorExpanded: $isColorExpanded,
                onParticleEffectChange: { screenManager.updateParticleEffect($0, for: screen) },
                onParticleDensityChange: { screenManager.updateParticleDensity($0, for: screen) },
                onWeatherReactiveChange: { screenManager.setWeatherReactive($0, for: screen) },
                onWallpaperModeChange: { screenManager.updateWallpaperMode($0, for: screen) },
                onResetDisplaySettings: requestResetDisplaySettings
            )
        }
    }

    private var inspectorPanelWidth: CGFloat {
        clampedInspectorWidth(CGFloat(liveInspectorWidth ?? inspectorWidth))
    }

    private var dropFailurePresented: Binding<Bool> {
        Binding(
            get: { dropFailure != nil },
            set: { if !$0 { dropFailure = nil } }
        )
    }

    @ViewBuilder
    private func dropFailureButtons(_ failure: DropFailure) -> some View {
        switch failure {
        case .invalidDropType(let suggestion):
            switch suggestion {
            case .video:
                Button("Choose Video…") { showFilePicker() }
            case .html:
                Button("Choose HTML…") { showHTMLSourcePicker() }
            case .metalShader, .scene:
                EmptyView()
            }
            Button("Cancel", role: .cancel) { }

        case .videoFormatUnsupported, .videoBookmarkFailed:
            Button("Choose Different Video…") { showFilePicker() }
            Button("Cancel", role: .cancel) { }

        case .htmlBookmarkFailed, .htmlPickerWrongType:
            Button("Choose Different Source…") { showHTMLSourcePicker() }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func requestResetDisplaySettings() {
        pendingDestructive = PendingDestructive(
            .resetDisplaySettings(displayName: screen.name)
        ) {
            screenManager.resetDisplaySettings(for: screen)
        }
    }

    private func clampedInspectorWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, DesignTokens.Inspector.minWidth), DesignTokens.Inspector.maxWidth)
    }

    private func previewInspectorWidth(_ width: CGFloat) {
        withoutResizeAnimation {
            liveInspectorWidth = Double(clampedInspectorWidth(width))
        }
    }

    private func commitInspectorWidth(_ width: CGFloat) {
        withoutResizeAnimation {
            inspectorWidth = Double(clampedInspectorWidth(width))
            liveInspectorWidth = nil
        }
    }

    private func withoutResizeAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }

    // MARK: - Drag and Drop
    private func handleDrop(urls: [URL]) -> Bool {
        defer { isDraggingOver = false }
        guard let droppedURL = urls.first else { return false }
        if isHTMLDrop(droppedURL) {
            applyHTMLDrop(droppedURL)
            return true
        }
        let videoURLs = urls.filter(ResourceUtilities.isSupportedVideoURL)
        guard let primaryURL = videoURLs.first else {
            dropFailure = .invalidDropType(suggestion: draft.selectedWallpaperType)
            return false
        }
        if videoURLs.count == 1 {
            handleSelectedFile(url: primaryURL)
        } else {
            handleMultipleVideoDrop(urls: videoURLs)
        }
        return true
    }

    private func handleMultipleVideoDrop(urls: [URL]) {
        guard let primaryURL = urls.first else { return }
        let bookmarks = urls.compactMap { ResourceUtilities.createVideoBookmark(for: $0) }
        guard let primaryBookmark = bookmarks.first, bookmarks.count == urls.count else {
            handleSelectedFile(url: primaryURL)
            return
        }
        withAnimation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2))) { isLoading = true }
        cleanupPreviewPlayer()
        draft.hasPreviewSource = true
        lastPreviewPosterBookmarkData = primaryBookmark
        previewController.startPlaybackPreview(from: primaryURL, syncTo: nil)
        screenManager.replacePlaylist(ordered: bookmarks, primary: primaryBookmark, for: screen)
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2))) { isLoading = false }
        }
    }

    private func isHTMLDrop(_ url: URL) -> Bool {
        ResourceUtilities.isSupportedHTMLResourceURL(url)
    }

    private func applyHTMLDrop(_ url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        let source: HTMLSource?
        if isDirectory.boolValue {
            guard let bookmark = ResourceUtilities.createBookmark(for: url) else {
                dropFailure = .htmlBookmarkFailed
                return
            }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            let indexFileName = ResourceUtilities.inferHTMLIndexFileName(from: entries)
            source = .folder(bookmarkData: bookmark, indexFileName: indexFileName)
        } else {
            source = ResourceUtilities.htmlSourceFromPickedFile(url)
        }

        guard let resolved = source else {
            dropFailure = .htmlBookmarkFailed
            return
        }
        draft.selectedWallpaperType = .html
        screenManager.setHTMLWallpaper(source: resolved, config: draft.htmlConfig, for: screen)
    }

    // MARK: - Helper Methods
    func setupPreviewPlayer() {
        guard let url = resolvePreviewVideoURL() else { return }
        previewController.startPlaybackPreview(from: url, syncTo: screen.videoPlayer?.player)
    }

    private func scheduleConfigurationLoad() {
        DispatchQueue.main.async {
            Task { @MainActor in
                loadScreenConfiguration()
            }
        }
    }

    private func loadScreenConfiguration() {
        if lockScreenExtracted { lockScreenExtracted = false }

        let config = screenManager.getConfiguration(for: screen)
        draft = .from(
            config: config,
            fallbackHasPreviewSource: screen.videoPlayer?.videoURL != nil
        )

        if config?.wallpaperType != .video {
            assignIfChanged(lastPreviewPosterBookmarkData, to: nil) { lastPreviewPosterBookmarkData = $0 }
        }
        if config == nil {
            previewController.cleanup()
        }
        loadPreviewPosterIfNeeded()
    }

    private func assignIfChanged<Value: Equatable>(
        _ currentValue: Value,
        to newValue: Value,
        assign: (Value) -> Void
    ) {
        guard currentValue != newValue else { return }
        assign(newValue)
    }

    private func cleanupPreviewPlayer() {
        lastPreviewPosterBookmarkData = nil
        draft.hasPreviewSource = false
        previewController.cleanup()
    }

    private func showFilePicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        handleSelectedFile(url: url)
    }

    /// Routes the banner's "Re-pick" button to the picker matching the current session type.
    private func rePickRuntimeSource() {
        let activeType = screen.runtimeSession?.wallpaperType ?? draft.selectedWallpaperType
        switch activeType {
        case .video:
            showFilePicker()
        case .html:
            showHTMLSourcePicker()
        case .metalShader, .scene:
            draft.selectedWallpaperType = activeType
        }
    }

    private func showHTMLSourcePicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard isHTMLDrop(url) else {
            dropFailure = .htmlPickerWrongType
            return
        }
        draft.selectedWallpaperType = .html
        applyHTMLDrop(url)
    }

    private func handleSelectedFile(url: URL) {
        guard ResourceUtilities.isSupportedVideoURL(url) else {
            dropFailure = .videoFormatUnsupported
            return
        }

        withAnimation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2))) { isLoading = true }
        cleanupPreviewPlayer()

        if let bookmarkData = ResourceUtilities.createVideoBookmark(for: url) {
            draft.hasPreviewSource = true
            lastPreviewPosterBookmarkData = bookmarkData
            previewController.startPlaybackPreview(from: url, syncTo: nil)
            screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
        } else {
            dropFailure = .videoBookmarkFailed
        }

        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2))) { isLoading = false }
        }
    }

    private func clearCurrentWallpaper() {
        pendingDestructive = PendingDestructive(
            .clearCurrentWallpaper(displayName: screen.name)
        ) {
            performClearWallpaper()
        }
    }

    private func performClearWallpaper() {
        cleanupPreviewPlayer()
        screenManager.clearWallpaperForScreen(screen)
    }

    private func requestApplyToAll() {
        let others = max(0, screenManager.screens.count - 1)
        pendingDestructive = PendingDestructive(
            .applyConfigurationToAllDisplays(otherCount: others)
        ) {
            screenManager.applyConfigurationToAllDisplays(from: screen)
        }
    }

    private func loadPreviewPosterIfNeeded() {
        guard previewController.player == nil else { return }

        if let config = screenManager.getConfiguration(for: screen),
           config.wallpaperType == .video,
           let bookmarkData = config.videoBookmarkData {
            if lastPreviewPosterBookmarkData == bookmarkData,
               previewController.posterImage != nil || previewController.isLoading {
                return
            }
            guard let url = resolvePreviewVideoURL() else { return }
            lastPreviewPosterBookmarkData = bookmarkData
            previewController.loadPoster(from: url, syncTime: screen.videoPlayer?.player?.currentTime())
            return
        }

        if lastPreviewPosterBookmarkData != nil {
            lastPreviewPosterBookmarkData = nil
        }
        guard let url = screen.videoPlayer?.videoURL else { return }
        previewController.loadPoster(from: url, syncTime: screen.videoPlayer?.player?.currentTime())
    }

    private func resolvePreviewVideoURL() -> URL? {
        if let config = screenManager.getConfiguration(for: screen),
           config.wallpaperType == .video,
           let bookmarkData = config.videoBookmarkData {
            guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                bookmarkData,
                target: .transient
            ) else { return nil }
            let url = resolved.url
            if resolved.didRefresh {
                screenManager.replaceActiveBookmark(resolved.bookmarkData, for: screen)
            }
            return url
        }

        return screen.videoPlayer?.videoURL
    }

    // MARK: - Empty State Guide

    /// Video card opens the existing file picker.
    private func triggerVideoGuideAction() {
        showFilePicker()
    }

    /// HTML / Shader / Scene cards flip the selected type so that type's empty state takes over.
    private func triggerHTMLGuideAction() {
        draft.selectedWallpaperType = .html
    }

    private func triggerShaderGuideAction() {
        draft.selectedWallpaperType = .metalShader
    }

    private func triggerSceneGuideAction() {
        draft.selectedWallpaperType = .scene
    }
}

