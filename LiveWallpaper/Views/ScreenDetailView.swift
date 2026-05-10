import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScreenDetailView: View {
    var screen: Screen
    @Environment(ScreenManager.self) private var screenManager

    @State private var playbackSpeed: Double = 1.0
    @State private var selectedFitMode: VideoFitMode = .aspectFill
    @State private var isLoading: Bool = false
    private var wallpaperSessionSummary: WallpaperSessionSummary {
        screenManager.wallpaperSummary(for: screen)
    }
    private var runtimeError: WallpaperRuntimeError? {
        screenManager.runtimeError(for: screen)
    }
    private var applyToAllConfirmationMessage: LocalizedStringKey {
        let others = max(0, screenManager.screens.count - 1)
        if others == 1 {
            return "This replaces the wallpaper on 1 other display with the same content and settings as this one."
        }
        return "This replaces the wallpaper on \(others) other displays with the same content and settings as this one."
    }

    @ViewBuilder
    private var runtimeErrorBannerView: some View {
        if let runtimeError {
            let activeType = screen.runtimeSession?.wallpaperType ?? selectedWallpaperType
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

    private var canApplyToAllDisplays: Bool {
        screenManager.screens.count > 1 && screenManager.getConfiguration(for: screen) != nil
    }

    @ViewBuilder
    private var wallpaperTypePicker: some View {
        Picker("Wallpaper Type", selection: $selectedWallpaperType) {
            ForEach(WallpaperType.allCases) { type in
                Text(type.titleKey).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text("Wallpaper type"))
        .accessibilityHint(Text("Choose wallpaper type"))
        .onChange(of: selectedWallpaperType) { _, newType in
            Logger.info("Wallpaper type selected for screen \(screen.id): \(newType.rawValue)", category: .ui)
            switch newType {
            case .video:
                screenManager.switchToVideoWallpaper(for: screen)
            case .html:
                screenManager.switchToHTMLWallpaper(for: screen)
            case .metalShader, .scene:
                break
            }
        }
    }

    private var wallpaperTypeToolbar: some View {
        wallpaperTypePicker
    }

    @ViewBuilder
    private var applyToAllButton: some View {
        if canApplyToAllDisplays {
            Button {
                showApplyToAllConfirm = true
            } label: {
                Label("Apply to All", systemImage: "square.on.square")
            }
            .help(Text("Copy this display's wallpaper and settings to every other display"))
            .accessibilityLabel(Text("Apply to all displays"))
            .accessibilityHint(Text("Copies the current wallpaper and settings to every other connected display"))
            .buttonStyle(.glass)
            .controlSize(.regular)
        }
    }
    /// Resolved Wallpaper Engine origin metadata for the active wallpaper, or
    /// nil when the user picked content directly. Recomputed on every body
    /// evaluation so save/import flows propagate without local @State.
    private var wpeOrigin: WPEOrigin? {
        screenManager.getConfiguration(for: screen)?.wpeOrigin
    }

    private var sessionStatusText: LocalizedStringKey {
        guard wallpaperSessionSummary.isConfigured else {
            return "Not configured"
        }

        return wallpaperSessionSummary.activity == .active ? "Playing" : "Paused"
    }
    private var sessionStatusColor: Color {
        switch wallpaperSessionSummary.activity {
        case .active:
            return .green
        case .paused:
            return .orange
        case .inactive:
            return .secondary
        }
    }

    private var hasConfigurableWallpaperSurface: Bool {
        if shouldShowGuideEmptyState { return false }
        if screenManager.getConfiguration(for: screen) != nil { return true }
        if screen.runtimeSession != nil { return true }
        if hasPreviewSource || previewController.hasPreviewContent { return true }
        return false
    }

    private var showsInspector: Bool {
        !shouldShowGuideEmptyState
            && hasConfigurableWallpaperSurface
            && [WallpaperType.video, .html].contains(selectedWallpaperType)
    }

    private var showsHeaderVideoActions: Bool {
        selectedWallpaperType == .video && !shouldShowGuideEmptyState
    }

    @State private var showErrorAlert = false
    @State private var errorMessage: LocalizedStringKey = ""
    @State private var showClearConfirm = false
    @State private var showApplyToAllConfirm = false
    @State private var previewController = InspectorPreviewController()
    @State private var hasPreviewSource = false
    @State private var lastPreviewPosterBookmarkData: Data?

    @State private var selectedWallpaperType: WallpaperType = .video
    @State private var selectedWallpaperMode: WallpaperMode = .single
    @State private var selectedParticleEffect: ParticleEffect = .none
    @State private var effectConfig = VideoEffectConfig.default
    @State private var selectedShaderPreset: MetalShaderPreset = .waves
    @State private var htmlSource: HTMLSource? = nil
    @State private var htmlConfig: HTMLConfig = .default
    @State private var setAsLockScreen: Bool = false

    @State private var playlistBookmarks: [Data] = []
    @State private var shufflePlaylist: Bool = false
    @State private var playlistRotationMinutes: Int? = nil
    @State private var scheduleSlots: [ScheduleSlot] = []

    @State private var isDraggingOver = false
    @State private var videoMuted: Bool = true
    @State private var lockScreenExtracted: Bool = false
    @State private var particleDensity: Double = 1.0
    @State private var selectedFrameRateLimit: FrameRateLimit = .fps60
    @State private var showBookmarks = false

    @AppStorage("Inspector.PlaylistExpanded") private var isPlaylistExpanded = false
    @AppStorage("Inspector.ScheduleExpanded") private var isScheduleExpanded = false
    @AppStorage("Inspector.EnvironmentExpanded") private var isEnvironmentExpanded = true
    @AppStorage("Inspector.ColorExpanded") private var isColorExpanded = false
    @AppStorage("Inspector.Width") private var inspectorWidth = Double(DesignTokens.Inspector.defaultWidth)
    @State private var liveInspectorWidth: Double?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            screenHeader

            runtimeErrorBannerView

            Divider()

            HStack(spacing: 0) {
                ZStack {
                    Color(NSColor.underPageBackgroundColor)

                    if shouldShowGuideEmptyState {
                        EmptyStateGuideView(
                            onChooseVideo: triggerVideoGuideAction,
                            onChooseHTML: triggerHTMLGuideAction,
                            onChooseShader: triggerShaderGuideAction,
                            onChooseScene: triggerSceneGuideAction
                        )
                    } else if selectedWallpaperType == .video {
                        if isLoading {
                            ScreenDetailLoadingView()
                        } else if hasPreviewSource || previewController.hasPreviewContent {
                            VStack(spacing: 16) {
                                if let origin = wpeOrigin {
                                    WPEOriginBadge(origin: origin) {
                                        selectedWallpaperType = .scene
                                    }
                                }
                                VideoPreviewSection(
                                    previewController: previewController,
                                    hasPreviewSource: hasPreviewSource,
                                    selectedFitMode: selectedFitMode,
                                    startPreview: setupPreviewPlayer
                                )
                                .aspectRatio(16/9, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)

                                VStack(spacing: 10) {
                                    HStack(spacing: 8) {
                                        ForEach(VideoFitMode.allCases) { mode in
                                            FitModeButton(mode: mode, isSelected: selectedFitMode == mode) {
                                                withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
                                                    selectedFitMode = mode
                                                }
                                                screenManager.updateFitMode(mode, for: screen)
                                            }
                                        }
                                    }

                                    Divider()

                                    HStack(spacing: 10) {
                                        Text("Speed")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.secondary)
                                        SegmentedSpeedPicker(selectedSpeed: $playbackSpeed) { speed in
                                            screen.videoPlayer?.setPlaybackSpeed(speed)
                                            screenManager.updatePlaybackSpeed(speed, for: screen)
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                                )
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                        } else {
                            ScreenDetailEmptyStateView(
                                isDraggingOver: isDraggingOver,
                                selectVideo: showFilePicker
                            )
                                .padding(24)
                        }
                    } else if selectedWallpaperType == .html {
                        VStack(spacing: 16) {
                            if let origin = wpeOrigin {
                                WPEOriginBadge(origin: origin) {
                                    selectedWallpaperType = .scene
                                }
                            }
                            HTMLSourceSection(
                                screen: screen,
                                source: $htmlSource,
                                config: $htmlConfig
                            )
                        }
                        .padding(24)
                    } else if selectedWallpaperType == .metalShader {
                        ShaderWallpaperSection(screen: screen, selectedShaderPreset: $selectedShaderPreset)
                            .padding(24)
                    } else if selectedWallpaperType == .scene {
                        WPESceneSection(screen: screen)
                    }
                }
                .frame(minWidth: DesignTokens.PreviewArea.minWidth, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .overlay {
                    dragHintOverlay
                        .animation(.smooth(duration: 0.2), value: isDraggingOver)
                }

                if showsInspector {
                    InspectorResizeHandle(
                        width: inspectorPanelWidth,
                        minWidth: DesignTokens.Inspector.minWidth,
                        maxWidth: DesignTokens.Inspector.maxWidth,
                        onPreviewWidthChange: previewInspectorWidth,
                        onCommitWidth: commitInspectorWidth
                    )
                    inspectorPanel
                        .layoutPriority(0)
                }
            }
            .transaction(value: selectedWallpaperType) { $0.animation = nil }
            .transaction(value: liveInspectorWidth) { $0.animation = nil }
        }
        .background(Color(NSColor.underPageBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .principal) {
                wallpaperTypeToolbar
            }
        }
        .confirmationDialog(
            "Apply this wallpaper to every other display?",
            isPresented: $showApplyToAllConfirm
        ) {
            Button("Apply to All Displays", role: .destructive) {
                screenManager.applyConfigurationToAllDisplays(from: screen)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(applyToAllConfirmationMessage)
        }
        .onAppear { loadScreenConfiguration() }
        .onDisappear { cleanupPreviewPlayer() }
        .onChange(of: screen.id) {
            cleanupPreviewPlayer()
            loadScreenConfiguration()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            guard let changedID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
                  changedID == screen.id else { return }
            loadScreenConfiguration()
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: { Text(errorMessage) }
        .confirmationDialog(
            "Clear Wallpaper Video",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Video", role: .destructive) {
                performClearVideo()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove this video and its settings for this display.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
        } isTargeted: { targeted in
            isDraggingOver = targeted
        }
    }

    private var screenHeader: some View {
        DetailHeaderBar(
            systemImage: "display",
            title: {
                HStack(spacing: 8) {
                    Text(verbatim: screen.name)

                    Button(action: { screenManager.reloadWallpaperForScreen(screen) }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Reload display content"))
                    .accessibilityLabel(Text("Reload display"))
                    .accessibilityHint(Text("Reloads the wallpaper content for this screen"))
                }
            },
            metadata: {
                HStack(spacing: DesignTokens.DetailHeader.metadataSpacing) {
                    InfoBadge(icon: "arrow.up.left.and.arrow.down.right", text: "\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                    InfoBadge(icon: "gauge.medium", text: "\(getScreenRefreshRate()) Hz")
                    if wallpaperSessionSummary.isConfigured {
                        HStack(spacing: 4) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(sessionStatusColor)
                                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: wallpaperSessionSummary.activity == .active)
                            Text(sessionStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            },
            actions: {
                HStack(spacing: 8) {
                    applyToAllButton

                    Button {
                        showBookmarks = true
                    } label: {
                        Label("Bookmarks", systemImage: "bookmark.fill")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .help(Text("Saved video / HTML / shader shortcuts"))
                    .accessibilityLabel(Text("Bookmarks"))
                    .popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
                        BookmarksPopover(screen: screen)
                            .environment(screenManager)
                    }

                    if showsHeaderVideoActions {
                        HStack(spacing: 8) {
                            Button {
                                showFilePicker()
                            } label: {
                                Label("Select Video", systemImage: "folder.badge.plus")
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.regular)
                            .help(Text("Choose a video file for this display"))
                            .accessibilityLabel(Text("Select video"))
                            .accessibilityHint(Text("Opens a file picker to choose a wallpaper video"))

                            Button(role: .destructive) {
                                clearVideo()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.glass)
                            .destructiveControlTint()
                            .controlSize(.regular)
                            .help(Text("Remove wallpaper video"))
                            .accessibilityLabel(Text("Clear video"))
                            .accessibilityHint(Text("Removes the current wallpaper video from this screen"))
                        }
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var inspectorPanel: some View {
        if showsInspector {
            ScrollView {
                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 16) {
                        CommonPlaybackInspector(
                            screen: screen,
                            wallpaperType: selectedWallpaperType,
                            muted: $videoMuted,
                            frameRateLimit: $selectedFrameRateLimit,
                            syncToLockScreen: $setAsLockScreen,
                            htmlConfig: selectedWallpaperType == .html ? $htmlConfig : nil
                        )

                        if selectedWallpaperType == .video {
                            VStack(spacing: 16) {
                                HStack(spacing: 0) {
                                    ForEach(WallpaperMode.allCases) { mode in
                                        Button {
                                            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) {
                                                selectedWallpaperMode = mode
                                            }
                                            screenManager.updateWallpaperMode(mode, for: screen)
                                        } label: {
                                            Text(mode.labelKey)
                                                .font(.system(size: 12, weight: selectedWallpaperMode == mode ? .semibold : .regular))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 5)
                                                .background(
                                                    Capsule()
                                                        .fill(selectedWallpaperMode == mode ? Color.accentColor.opacity(0.35) : Color.clear)
                                                )
                                                .contentShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(wallpaperModeAccessibilityLabel(mode))
                                    }
                                }
                                .padding(2)
                                .glassEffect(.regular.interactive(), in: .capsule)

                                if selectedWallpaperMode == .playlist {
                                    GroupBox {
                                        CollapsibleSection(
                                            title: "Playlist",
                                            systemImage: "list.bullet",
                                            isExpanded: $isPlaylistExpanded
                                        ) {
                                            PlaylistSection(
                                                playlistBookmarks: $playlistBookmarks,
                                                shufflePlaylist: $shufflePlaylist,
                                                rotationMinutes: $playlistRotationMinutes,
                                                screen: screen,
                                                screenManager: screenManager
                                            )
                                        }
                                    }
                                    .groupBoxStyle(ContainerGroupBoxStyle())
                                    .transition(reduceMotion ? .opacity : .asymmetric(
                                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                                        removal: .opacity
                                    ))
                                }

                                if selectedWallpaperMode == .schedule {
                                    GroupBox {
                                        CollapsibleSection(
                                            title: "Schedule",
                                            systemImage: "clock",
                                            isExpanded: $isScheduleExpanded
                                        ) {
                                            ScheduleSection(
                                                scheduleSlots: $scheduleSlots,
                                                screen: screen,
                                                screenManager: screenManager
                                            )
                                        }
                                    }
                                    .groupBoxStyle(ContainerGroupBoxStyle())
                                    .transition(reduceMotion ? .opacity : .asymmetric(
                                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                                        removal: .opacity
                                    ))
                                }

                                GroupBox {
                                    CollapsibleSection(
                                        title: "Environment",
                                        systemImage: "cloud.sun.rain",
                                        isExpanded: $isEnvironmentExpanded
                                    ) {
                                        VStack(spacing: 8) {
                                            SettingRow(icon: "sparkles", iconColor: .purple, title: "Particles") {
                                                Picker("", selection: $selectedParticleEffect) {
                                                    ForEach(ParticleEffect.allCases) { effect in
                                                        Text(effect.titleKey).tag(effect)
                                                    }
                                                }
                                                .labelsHidden()
                                                .frame(width: 86)
                                                .onChange(of: selectedParticleEffect) { _, newValue in
                                                    screenManager.updateParticleEffect(newValue, for: screen)
                                                }
                                                .accessibilityLabel(Text("Particle effect"))
                                                .accessibilityValue(Text(selectedParticleEffect.titleKey))
                                                .accessibilityHint(Text("Choose a particle overlay effect"))
                                                .help(Text("Overlay particle effects on the wallpaper"))
                                            }

                                            if selectedParticleEffect != .none {
                                                SettingRow(icon: "circle.hexagongrid", iconColor: .purple, title: "Density") {
                                                    HStack(spacing: 8) {
                                                        Slider(value: $particleDensity, in: 0.2...3.0)
                                                            .controlSize(.small)
                                                            .frame(width: 80)
                                                            .onChange(of: particleDensity) { _, newValue in
                                                                screenManager.updateParticleDensity(newValue, for: screen)
                                                            }
                                                            .accessibilityLabel(Text("Particle density"))
                                                            .accessibilityValue(String(format: "%.1f×", particleDensity))
                                                        Text(String(format: "%.1f", particleDensity))
                                                            .font(.system(size: 12, design: .monospaced))
                                                            .foregroundStyle(.secondary)
                                                            .frame(width: 28, alignment: .trailing)
                                                    }
                                                }
                                            }

                                            Divider()

                                            SettingRow(icon: "cloud.sun", iconColor: .cyan, title: "Weather") {
                                                Toggle("", isOn: $effectConfig.weatherReactive)
                                                    .labelsHidden()
                                                    .toggleStyle(.switch)
                                                    .onChange(of: effectConfig.weatherReactive) { _, newValue in
                                                        screenManager.setWeatherReactive(newValue, for: screen)
                                                    }
                                                    .help(Text("Adjust effects based on real-time weather conditions"))
                                                    .accessibilityLabel(Text("Weather-reactive effects"))
                                                    .accessibilityHint(Text("Automatically adjust particles and color based on real-time weather"))
                                            }

                                            if effectConfig.weatherReactive {
                                                WeatherStatusBadge(
                                                    weatherService: screenManager.weatherService,
                                                    refresh: screenManager.weatherService.refresh
                                                )
                                            }
                                        }
                                    }
                                }
                                .groupBoxStyle(ContainerGroupBoxStyle())

                                GroupBox {
                                    CollapsibleSection(
                                        title: "Color & Filters",
                                        systemImage: "slider.horizontal.3",
                                        isExpanded: $isColorExpanded
                                    ) {
                                        ColorAdjustmentsView(effectConfig: $effectConfig, screen: screen, screenManager: screenManager)
                                    }
                                }
                                .groupBoxStyle(ContainerGroupBoxStyle())
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                }
            }
            .frame(width: inspectorPanelWidth)
            .fixedSize(horizontal: true, vertical: false)
            .background(Color(NSColor.windowBackgroundColor))
            .clipped()
            .accessibilityLabel(Text("Wallpaper Properties"))
        }
    }

    private var inspectorPanelWidth: CGFloat {
        clampedInspectorWidth(CGFloat(liveInspectorWidth ?? inspectorWidth))
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

    // MARK: - Drag Hint Overlay

    @ViewBuilder
    private var dragHintOverlay: some View {
        if isDraggingOver {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.bounce, options: .repeat(.continuous))
                    Text("Drop to use as wallpaper")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(dragHintSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .transition(.opacity)
            // Drop handling stays on the outer view.
            .allowsHitTesting(false)
        }
    }

    private var dragHintSubtitle: LocalizedStringKey {
        switch selectedWallpaperType {
        case .video:        return "Video file (.mp4, .mov, …)"
        case .html:         return "HTML file or folder"
        case .metalShader:  return "Switch to Video or HTML to drop"
        case .scene:        return "Switch to Video or HTML to drop"
        }
    }

    // MARK: - Drag and Drop
    private func handleDrop(urls: [URL]) -> Bool {
        defer { isDraggingOver = false }
        guard let droppedURL = urls.first else { return false }
        if isHTMLDrop(droppedURL) {
            applyHTMLDrop(droppedURL)
            return true
        }
        handleSelectedFile(url: droppedURL)
        return true
    }

    private func isHTMLDrop(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else { return false }
        if isDirectory.boolValue {
            return true
        }
        return url.pathExtension.lowercased() == "html" || url.pathExtension.lowercased() == "htm"
    }

    private func applyHTMLDrop(_ url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        let source: HTMLSource?
        if isDirectory.boolValue {
            guard let bookmark = ResourceUtilities.createBookmark(for: url) else {
                errorMessage = "Failed to bookmark dropped HTML resource."
                showErrorAlert = true
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
            errorMessage = "Failed to bookmark dropped HTML resource."
            showErrorAlert = true
            return
        }
        selectedWallpaperType = .html
        screenManager.setHTMLWallpaper(source: resolved, config: htmlConfig, for: screen)
    }

    // MARK: - Helper Methods
    func setupPreviewPlayer() {
        guard let url = resolvePreviewVideoURL() else { return }
        previewController.startPlaybackPreview(from: url, syncTo: screen.videoPlayer?.player)
    }

    private func loadScreenConfiguration() {
        lockScreenExtracted = false

        if let config = screenManager.getConfiguration(for: screen) {
            if playbackSpeed != config.playbackSpeed { playbackSpeed = config.playbackSpeed }
            if selectedFitMode != config.fitMode { selectedFitMode = config.fitMode }

            selectedParticleEffect = config.particleEffect
            effectConfig = config.effectConfig
            particleDensity = config.effectConfig.particleDensity
            setAsLockScreen = config.setAsLockScreen
            videoMuted = config.muted
            selectedFrameRateLimit = config.frameRateLimit
            playlistBookmarks = config.playlistBookmarks ?? []
            shufflePlaylist = config.shufflePlaylist
            playlistRotationMinutes = config.playlistRotationMinutes
            scheduleSlots = config.scheduleSlots ?? []
            if let preset = config.shaderPreset { selectedShaderPreset = preset }
            selectedWallpaperType = config.wallpaperType
            selectedWallpaperMode = config.wallpaperMode
            htmlSource = config.htmlSource
            htmlConfig = config.htmlConfig ?? .default
            hasPreviewSource = config.wallpaperType == .video && config.videoBookmarkData != nil
            if config.wallpaperType != .video {
                lastPreviewPosterBookmarkData = nil
            }
            loadPreviewPosterIfNeeded()
        } else {
            playbackSpeed = 1.0
            selectedFitMode = .aspectFill
            selectedParticleEffect = .none
            effectConfig = .default
            particleDensity = 1.0
            setAsLockScreen = false
            selectedFrameRateLimit = .fps60
            playlistBookmarks = []
            shufflePlaylist = false
            playlistRotationMinutes = nil
            scheduleSlots = []
            selectedWallpaperType = .video
            selectedWallpaperMode = .single
            htmlSource = nil
            htmlConfig = .default
            hasPreviewSource = screen.videoPlayer?.videoURL != nil
            lastPreviewPosterBookmarkData = nil
            loadPreviewPosterIfNeeded()
        }
    }

    private func cleanupPreviewPlayer() {
        lastPreviewPosterBookmarkData = nil
        previewController.cleanup()
    }

    private func showFilePicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie, .avi]
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        handleSelectedFile(url: url)
    }

    /// Routes the banner's "Re-pick" button to the picker matching the current
    /// session type. Falls back to the video picker for non-pickable backends
    /// (scene / shader sessions are switched via the type segmented control).
    private func rePickRuntimeSource() {
        let activeType = screen.runtimeSession?.wallpaperType ?? selectedWallpaperType
        switch activeType {
        case .video:
            showFilePicker()
        case .html:
            showHTMLSourcePicker()
        case .metalShader, .scene:
            selectedWallpaperType = activeType
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
            errorMessage = "Choose an HTML file or folder."
            showErrorAlert = true
            return
        }
        selectedWallpaperType = .html
        applyHTMLDrop(url)
    }

    private func handleSelectedFile(url: URL) {
        withAnimation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2))) { isLoading = true }
        cleanupPreviewPlayer()

        if let bookmarkData = ResourceUtilities.createBookmark(for: url) {
            hasPreviewSource = true
            lastPreviewPosterBookmarkData = bookmarkData
            previewController.startPlaybackPreview(from: url, syncTo: nil)
            screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
        } else {
            errorMessage = "Error creating secure bookmark. Please try selecting a different video file."
            showErrorAlert = true
        }

        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2))) { isLoading = false }
        }
    }

    private func clearVideo() {
        showClearConfirm = true
    }

    private func performClearVideo() {
        cleanupPreviewPlayer()
        screenManager.clearWallpaperForScreen(screen)
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

        lastPreviewPosterBookmarkData = nil
        guard let url = screen.videoPlayer?.videoURL else { return }
        previewController.loadPoster(from: url, syncTime: screen.videoPlayer?.player?.currentTime())
    }

    private func resolvePreviewVideoURL() -> URL? {
        if let config = screenManager.getConfiguration(for: screen),
           config.wallpaperType == .video,
           let bookmarkData = config.videoBookmarkData {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            if isStale, let refreshed = ResourceUtilities.createBookmark(for: url) {
                screenManager.replaceActiveBookmark(refreshed, for: screen)
            }
            return url
        }

        return screen.videoPlayer?.videoURL
    }

    private func getScreenRefreshRate() -> Int {
        screenManager.getScreenRefreshRate(for: screen.id)
    }

    private func wallpaperModeAccessibilityLabel(_ mode: WallpaperMode) -> Text {
        switch mode {
        case .single:
            return Text("Single mode", comment: "A11y label for the single wallpaper mode tab.")
        case .playlist:
            return Text("Playlist mode", comment: "A11y label for the playlist wallpaper mode tab.")
        case .schedule:
            return Text("Schedule mode", comment: "A11y label for the schedule wallpaper mode tab.")
        }
    }

    // MARK: - Empty State Guide

    /// True when this screen has no persisted configuration, no live runtime
    /// session, and the user is still on the default Video type. Picking any
    /// other toolbar segment or guide card exits the first-run guide.
    private var shouldShowGuideEmptyState: Bool {
        if isLoading { return false }
        if selectedWallpaperType != .video { return false }
        if screenManager.getConfiguration(for: screen) != nil { return false }
        if screen.runtimeSession != nil { return false }
        if hasPreviewSource || previewController.hasPreviewContent { return false }
        return true
    }

    /// Video card opens the existing file picker. Cancellation returns the
    /// user to the guide unchanged.
    private func triggerVideoGuideAction() {
        showFilePicker()
    }

    /// HTML / Shader / Scene cards flip the selected type so that type's
    /// empty state takes over.
    private func triggerHTMLGuideAction() {
        selectedWallpaperType = .html
    }

    private func triggerShaderGuideAction() {
        selectedWallpaperType = .metalShader
    }

    private func triggerSceneGuideAction() {
        selectedWallpaperType = .scene
    }
}

private struct InspectorResizeHandle: View {
    let width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let onPreviewWidthChange: (CGFloat) -> Void
    let onCommitWidth: (CGFloat) -> Void

    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            Rectangle()
                .fill(Color(NSColor.separatorColor).opacity(isActive ? 0.9 : 0.45))
                .frame(width: isActive ? 2 : 1)

            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 34)
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isActive ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.10),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: Color.black.opacity(isActive ? 0.16 : 0.08), radius: 5, x: 0, y: 2)
                .accessibilityHidden(true)
        }
        .frame(width: 18)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? width
                    if dragStartWidth == nil {
                        dragStartWidth = start
                    }
                    isDragging = true
                    onPreviewWidthChange(clamped(start - value.translation.width))
                }
                .onEnded { value in
                    let start = dragStartWidth ?? width
                    onCommitWidth(clamped(start - value.translation.width))
                    dragStartWidth = nil
                    isDragging = false
                }
        )
        .onHover { isHovering = $0 }
        .help(Text("Drag to resize properties panel"))
        .accessibilityLabel(Text("Resize properties panel"))
        .accessibilityHint(Text("Drag horizontally to change the properties panel width"))
    }

    private var isActive: Bool {
        isHovering || isDragging
    }

    private func clamped(_ candidate: CGFloat) -> CGFloat {
        min(max(candidate, minWidth), maxWidth)
    }
}
