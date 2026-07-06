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
            screenManager.switchToShaderWallpaper(for: screen)
        case .scene:
            break
        case .monitor:
            guard featureCatalog.isEnabled(.monitorWallpaper) else { return }
            screenManager.switchToMonitorWallpaper(for: screen)
        }
    }

    /// Collapses three booleans that were computed inline from overlapping
    /// store/runtime state into one place so the rules stay auditable.
    private struct DerivedViewState {
        var showsGuideEmptyState: Bool
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
            case .scene:
                // Mount once a real scene config loads so the WPE Project
                // Custom Settings card can surface author-defined properties
                // (schemecolor, sliders). Inspector rows gate video-only
                // content internally.
                return config?.wallpaperType == .scene
            case .monitor:
                // Mount once a real monitor config loads so the inspector can
                // surface module toggles + authorization rows.
                return config?.wallpaperType == .monitor
            case .metalShader:
                return false
            }
        }()

        return DerivedViewState(
            showsGuideEmptyState: showsGuide,
            showsInspector: showsInspector,
            showsHeaderWallpaperActions: hasConfigurable
        )
    }

    private var shouldShowGuideEmptyState: Bool { derivedState.showsGuideEmptyState }
    private var inspectorApplicable: Bool { derivedState.showsInspector }
    /// Final visibility = applicable AND the user hasn't collapsed the panel.
    private var showsInspector: Bool { inspectorApplicable && inspectorUserVisible }
    private var showsHeaderWallpaperActions: Bool { derivedState.showsHeaderWallpaperActions }

    /// Each case carries enough context to render a meaningful retry / re-pick
    /// action instead of a dead-end "OK" dismissal.
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
            case .htmlBookmarkFailed:     return "Couldn't open web resource"
            case .htmlPickerWrongType:    return "Pick a web file or folder"
            }
        }

        var message: LocalizedStringKey {
            switch self {
            case .invalidDropType:
                return "Drop a video file, web file, or folder to use it as a wallpaper."
            case .videoFormatUnsupported:
                return "Choose an .mp4, .mov, .m4v, or similar video file."
            case .videoBookmarkFailed:
                return "macOS couldn't grant the app secure access to that file. Try a different video, or move the file to a folder you own."
            case .htmlBookmarkFailed:
                return "macOS couldn't grant the app secure access to that resource. Try moving it to a folder you own."
            case .htmlPickerWrongType:
                return "The selection isn't a web file or a folder containing an index page."
            }
        }
    }

    @State private var dropFailure: DropFailure?
    @State private var pendingDestructive: PendingDestructive?
    @State private var previewController = InspectorPreviewController()
    @State private var lastPreviewPosterBookmarkData: Data?

    @State private var isDraggingOver = false
    @State private var showBookmarks = false

    @AppStorage("Inspector.EnvironmentExpanded") private var isEnvironmentExpanded = true
    @AppStorage("Inspector.ColorExpanded") private var isColorExpanded = false
    @AppStorage("Inspector.Width") private var inspectorWidth = Double(DesignTokens.Inspector.defaultWidth)
    @State private var liveInspectorWidth: Double?
    /// Persisted so a collapsed inspector stays collapsed across launches.
    @AppStorage("Inspector.Visible") private var inspectorUserVisible = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ResizableInspectorSplit(
            isMounted: inspectorApplicable,
            isVisible: showsInspector,
            // Keyed on the user toggle, not `showsInspector`, so switching
            // wallpaper type (which flips `inspectorApplicable`) stays instant.
            animationTrigger: AnyHashable(inspectorUserVisible),
            reduceMotion: reduceMotion,
            storedWidth: $inspectorWidth,
            liveWidth: $liveInspectorWidth,
            // Dragging the handle past the panel's minimum collapses it — the
            // direct-manipulation mirror of the toolbar toggle.
            onClose: { inspectorUserVisible = false },
            main: { mainColumn },
            inspector: { width in inspectorPanel(width: width) }
        )
        .background(DesignTokens.Colors.pageBackground)
        .toolbar {
            ToolbarItem(placement: .principal) {
                wallpaperTypePicker
            }
            // Gated on `inspectorApplicable` (not visibility) so the button
            // never moves when the user just flips the panel open/closed.
            if inspectorApplicable {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // No withAnimation: a toolbar button lives in the
                        // separate NSToolbar host, so its transaction doesn't
                        // reach the GeometryReader content. The width glide is
                        // driven by `.animation(value:)` on the layout instead.
                        inspectorUserVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(Text(inspectorUserVisible ? "Hide the properties panel" : "Show the properties panel"))
                    .accessibilityLabel(Text("Toggle properties panel"))
                    .accessibilityHint(Text("Show or hide the wallpaper properties on the right"))
                }
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

    private var mainColumn: some View {
        VStack(spacing: 0) {
            screenHeader

            runtimeErrorBannerView

            Divider()

            ScreenDetailPreviewArea(
                screen: screen,
                draft: $draft,
                featureCatalog: featureCatalog,
                previewController: previewController,
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
            onClearWallpaper: clearCurrentWallpaper,
            onApplyScene: applySceneAction
        )
    }

    /// `nil` in Lite (no scene support / no folder picker).
    private var applySceneAction: (() -> Void)? {
        #if !LITE_BUILD
        return {
            guard let url = WPEFolderPicker.chooseImportFolder() else { return }
            Task { @MainActor in
                await screenManager.importWallpaperEngineProject(at: url, for: screen)
            }
        }
        #else
        return nil
        #endif
    }

    private func inspectorPanel(width: CGFloat) -> some View {
        ScreenDetailInspectorPanel(
            screen: screen,
            draft: $draft,
            screenManager: screenManager,
            featureCatalog: featureCatalog,
            reduceMotion: reduceMotion,
            inspectorPanelWidth: width,
            isEnvironmentExpanded: $isEnvironmentExpanded,
            isColorExpanded: $isColorExpanded,
            onParticleEffectChange: { screenManager.updateParticleEffect($0, for: screen) },
            onParticleDensityChange: { screenManager.updateParticleDensity($0, for: screen) },
            onWeatherReactiveChange: { screenManager.setWeatherReactive($0, for: screen) },
            onWallpaperModeChange: { screenManager.updateWallpaperMode($0, for: screen) },
            showsResetPlayback: screenManager.displayPlaybackDiffersFromDefaults(for: screen),
            onResetPlaybackSettings: resetPlaybackSettings,
            showsResetDisplaySettings: screenManager.displaySettingsDifferFromDefaults(for: screen),
            onResetDisplaySettings: requestResetDisplaySettings
        )
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
                Button("Choose Web…") { showHTMLSourcePicker() }
            case .metalShader, .scene, .monitor:
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

    private func resetPlaybackSettings() {
        screenManager.resetPlaybackSettings(for: screen)
        loadScreenConfiguration()
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
        previewController.loadPoster(from: primaryURL, syncTime: nil)
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
        if let config = screenManager.getConfiguration(for: screen),
           config.wallpaperType == .video {
            lastPreviewPosterBookmarkData = config.videoBookmarkData
        }
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
        let config = screenManager.getConfiguration(for: screen)
        draft = .from(
            config: config,
            fallbackHasPreviewSource: screen.videoPlayer?.videoURL != nil
        )

        if config?.wallpaperType != .video, lastPreviewPosterBookmarkData != nil {
            lastPreviewPosterBookmarkData = nil
        }
        if config == nil {
            previewController.cleanup()
        }

        // If the preview is currently playing a video and the active wallpaper
        // bookmark has shifted (user hit Next/Prev/Play Now in the playlist,
        // rotation timer fired, etc.), restart the preview player against the
        // new URL. Without this `loadPreviewPosterIfNeeded()` early-exits on
        // `player != nil` and the inspector keeps showing the previous clip.
        if previewController.player != nil,
           let config,
           config.wallpaperType == .video,
           let activeBookmark = config.videoBookmarkData,
           activeBookmark != lastPreviewPosterBookmarkData {
            setupPreviewPlayer()
            return
        }

        loadPreviewPosterIfNeeded()
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

    private func rePickRuntimeSource() {
        let activeType = screen.runtimeSession?.wallpaperType ?? draft.selectedWallpaperType
        switch activeType {
        case .video:
            showFilePicker()
        case .html:
            showHTMLSourcePicker()
        case .metalShader, .scene, .monitor:
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
            previewController.loadPoster(from: url, syncTime: nil)
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

    /// Full clear: the trash button removes the screen's WHOLE wallpaper
    /// configuration and tears down the live session, whatever type is running.
    /// The previous per-type clear only dropped the selected tab's saved state —
    /// so with mixed types (e.g. a video tab open while a web wallpaper is
    /// active) it left the running pipeline alive / fell back to the other saved
    /// type instead of actually clearing the screen.
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

    private func triggerVideoGuideAction() {
        showFilePicker()
    }

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
