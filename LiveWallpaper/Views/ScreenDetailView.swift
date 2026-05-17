import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScreenDetailView: View {
    var screen: Screen
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog

    @State private var playbackSpeed: Double = 1.0
    @State private var selectedFitMode: VideoFitMode = .aspectFill
    @State private var selectedVideoDisplayMode: VideoDisplayMode = .perDisplay
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
            get: { selectedWallpaperType },
            set: { newType in
                guard selectedWallpaperType != newType else { return }
                selectedWallpaperType = newType
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
        case .metalShader, .scene:
            break
        }
    }

    @ViewBuilder
    private var applyToAllButton: some View {
        if canApplyToAllDisplays {
            Button {
                requestApplyToAll()
            } label: {
                Image(systemName: "square.on.square")
            }
            .help(Text("Apply to All — copy this display's wallpaper and settings to every other display"))
            .accessibilityLabel(Text("Apply to all displays"))
            .accessibilityHint(Text("Copies the current wallpaper and settings to every other connected display"))
            .adaptiveGlassButton(.regular)
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
        guard !shouldShowGuideEmptyState, hasConfigurableWallpaperSurface else {
            return false
        }
        switch selectedWallpaperType {
        case .video:
            return hasConfiguredVideoWallpaper
        case .html:
            return true
        case .metalShader, .scene:
            return false
        }
    }

    private var hasConfiguredVideoWallpaper: Bool {
        guard let config = screenManager.getConfiguration(for: screen),
              config.wallpaperType == .video else {
            return false
        }
        return config.hasConfiguredVideoSource
    }

    private var showsHeaderWallpaperActions: Bool {
        hasConfigurableWallpaperSurface && !shouldShowGuideEmptyState
    }

    @State private var showErrorAlert = false
    @State private var errorMessage: LocalizedStringKey = ""
    @State private var pendingDestructive: PendingDestructive?
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
    @State private var videoVolume: Double = 1.0
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
                    DesignTokens.Colors.pageBackground

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
                                #if !LITE_BUILD
                                if let origin = wpeOrigin, featureCatalog.isEnabled(.wpeImport) {
                                    WPEOriginBadge(origin: origin) {
                                        selectedWallpaperType = .scene
                                    }
                                }
                                #endif
                                if featureCatalog.isEnabled(.inspectorPreview) {
                                    VideoPreviewSection(
                                        previewController: previewController,
                                        hasPreviewSource: hasPreviewSource,
                                        selectedFitMode: selectedFitMode,
                                        startPreview: setupPreviewPlayer
                                    )
                                    .aspectRatio(16/9, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
                                }

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
                            #if !LITE_BUILD
                            if let origin = wpeOrigin, featureCatalog.isEnabled(.wpeImport) {
                                WPEOriginBadge(origin: origin) {
                                    selectedWallpaperType = .scene
                                }
                            }
                            #endif
                            if featureCatalog.isEnabled(.inspectorPreview), htmlSource != nil {
                                HTMLPreviewSection(source: htmlSource, config: htmlConfig)
                            }
                            HTMLSourceSection(
                                screen: screen,
                                source: $htmlSource,
                                config: $htmlConfig
                            )
                        }
                        .padding(24)
                    } else if selectedWallpaperType == .metalShader,
                              featureCatalog.isEnabled(.metalShader) {
                        ShaderWallpaperSection(screen: screen, selectedShaderPreset: $selectedShaderPreset)
                            .padding(24)
                    } else if selectedWallpaperType == .scene,
                              featureCatalog.isEnabled(.scene) {
                        #if !LITE_BUILD
                        WPESceneSection(screen: screen)
                        #else
                        EmptyView()
                        #endif
                    }
                }
                .frame(minWidth: DesignTokens.PreviewArea.minWidth, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .overlay {
                    dragHintOverlay
                        .animation(.smooth(duration: 0.2), value: isDraggingOver)
                }

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
            .transaction(value: selectedWallpaperType) { $0.animation = nil }
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
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: { Text(errorMessage) }
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
                                .symbolEffect(.pulse, options: .continuouslyRepeating, isActive: wallpaperSessionSummary.activity == .active)
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
                        Image(systemName: "bookmark.fill")
                    }
                    .adaptiveGlassButton(.regular)
                    .controlSize(.regular)
                    .help(Text("Bookmarks — saved video / HTML / shader shortcuts"))
                    .accessibilityLabel(Text("Bookmarks"))
                    .popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
                        BookmarksPopover(screen: screen)
                            .environment(screenManager)
                    }

                    if showsHeaderWallpaperActions {
                        HStack(spacing: 8) {
                            if selectedWallpaperType == .video {
                                Button {
                                    showFilePicker()
                                } label: {
                                    Image(systemName: "folder.badge.plus")
                                }
                                .adaptiveGlassButton(.prominent)
                                .controlSize(.regular)
                                .help(Text("Select Video — choose a video file for this display"))
                                .accessibilityLabel(Text("Select video"))
                                .accessibilityHint(Text("Opens a file picker to choose a wallpaper video"))
                            }

                            Button(role: .destructive) {
                                clearCurrentWallpaper()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .adaptiveGlassButton(.regular)
                            .destructiveControlTint()
                            .controlSize(.regular)
                            .help(Text("Clear Wallpaper — remove the current wallpaper without deleting source files"))
                            .accessibilityLabel(Text("Clear current wallpaper"))
                            .accessibilityHint(Text("Removes the current wallpaper from this screen without deleting source files or library items"))
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
                AdaptiveGlassContainer(spacing: 16) {
                    VStack(spacing: 16) {
                        CommonPlaybackInspector(
                            screen: screen,
                            wallpaperType: selectedWallpaperType,
                            muted: $videoMuted,
                            videoVolume: $videoVolume,
                            videoDisplayMode: $selectedVideoDisplayMode,
                            frameRateLimit: $selectedFrameRateLimit,
                            syncToLockScreen: $setAsLockScreen,
                            htmlConfig: selectedWallpaperType == .html ? $htmlConfig : nil
                        )

                        if selectedWallpaperType == .html {
                            HTMLOptionsInspector(
                                screen: screen,
                                config: $htmlConfig
                            )

                            HTMLRenderingDiagnosticsInspector(
                                screen: screen,
                                source: htmlSource,
                                config: htmlConfig
                            )
                        }

                        if selectedWallpaperType == .video,
                           featureCatalog.capabilities.selectableWallpaperModes.count > 1 {
                            VStack(spacing: 16) {
                                HStack(spacing: 0) {
                                    ForEach(featureCatalog.capabilities.selectableWallpaperModes) { mode in
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
                                .adaptiveGlassSurface(.capsule, interactive: true)

                                if selectedWallpaperMode == .playlist,
                                   featureCatalog.isEnabled(.playlists) {
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

                                if selectedWallpaperMode == .schedule,
                                   featureCatalog.isEnabled(.scheduleAutomation) {
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

                                if featureCatalog.isEnabled(.videoEffects) {
                                GroupBox {
                                    CollapsibleSection(
                                        title: "Environment",
                                        systemImage: "cloud.sun.rain",
                                        isExpanded: $isEnvironmentExpanded
                                    ) {
                                        VStack(spacing: 8) {
                                            SettingRow(icon: "sparkles", iconColor: .purple, title: "Particles") {
                                                Picker("", selection: particleEffectBinding) {
                                                    ForEach(ParticleEffect.allCases) { effect in
                                                        Text(effect.titleKey).tag(effect)
                                                    }
                                                }
                                                .labelsHidden()
                                                .frame(width: 86)
                                                .accessibilityLabel(Text("Particle effect"))
                                                .accessibilityValue(Text(selectedParticleEffect.titleKey))
                                                .accessibilityHint(Text("Choose a particle overlay effect"))
                                                .help(Text("Overlay particle effects on the wallpaper"))
                                            }

                                            if selectedParticleEffect != .none {
                                                SettingRow(icon: "circle.hexagongrid", iconColor: .purple, title: "Density") {
                                                    HStack(spacing: 8) {
                                                        Slider(value: particleDensityBinding, in: 0.2...3.0)
                                                            .controlSize(.small)
                                                            .frame(width: 80)
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
                                                Toggle("", isOn: weatherReactiveBinding)
                                                    .labelsHidden()
                                                    .toggleStyle(.switch)
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
                                } // end videoEffects gate
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

    private var particleEffectBinding: Binding<ParticleEffect> {
        Binding(
            get: { selectedParticleEffect },
            set: { newValue in
                guard selectedParticleEffect != newValue else { return }
                selectedParticleEffect = newValue
                screenManager.updateParticleEffect(newValue, for: screen)
            }
        )
    }

    private var particleDensityBinding: Binding<Double> {
        Binding(
            get: { particleDensity },
            set: { newValue in
                guard abs(particleDensity - newValue) > 0.001 else { return }
                particleDensity = newValue
                screenManager.updateParticleDensity(newValue, for: screen)
            }
        )
    }

    private var weatherReactiveBinding: Binding<Bool> {
        Binding(
            get: { effectConfig.weatherReactive },
            set: { newValue in
                guard effectConfig.weatherReactive != newValue else { return }
                effectConfig.weatherReactive = newValue
                screenManager.setWeatherReactive(newValue, for: screen)
            }
        )
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
                    Group {
                        if #available(macOS 15.0, *) {
                            Image(systemName: "arrow.down.doc.fill")
                                .symbolEffect(.bounce, options: .repeat(.continuous))
                        } else {
                            // macOS 14: .bounce cannot repeat indefinitely.
                            // Substitute .pulse so the affordance still draws
                            // the eye while a drag is in progress.
                            Image(systemName: "arrow.down.doc.fill")
                                .symbolEffect(.pulse, options: .continuouslyRepeating)
                        }
                    }
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
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
        guard ResourceUtilities.isSupportedVideoURL(droppedURL) else {
            errorMessage = "Choose a video file, HTML file, or folder."
            showErrorAlert = true
            return false
        }
        handleSelectedFile(url: droppedURL)
        return true
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

    private func scheduleConfigurationLoad() {
        DispatchQueue.main.async {
            Task { @MainActor in
                loadScreenConfiguration()
            }
        }
    }

    private func loadScreenConfiguration() {
        if lockScreenExtracted { lockScreenExtracted = false }

        if let config = screenManager.getConfiguration(for: screen) {
            assignIfChanged(playbackSpeed, to: config.playbackSpeed) { playbackSpeed = $0 }
            assignIfChanged(selectedFitMode, to: config.fitMode) { selectedFitMode = $0 }
            assignIfChanged(selectedVideoDisplayMode, to: config.videoDisplayMode) { selectedVideoDisplayMode = $0 }
            assignIfChanged(selectedParticleEffect, to: config.particleEffect) { selectedParticleEffect = $0 }
            assignIfChanged(effectConfig, to: config.effectConfig) { effectConfig = $0 }
            assignIfChanged(particleDensity, to: config.effectConfig.particleDensity) { particleDensity = $0 }
            assignIfChanged(setAsLockScreen, to: config.setAsLockScreen) { setAsLockScreen = $0 }
            assignIfChanged(videoMuted, to: config.muted) { videoMuted = $0 }
            assignIfChanged(videoVolume, to: config.videoVolume) { videoVolume = $0 }
            assignIfChanged(selectedFrameRateLimit, to: config.frameRateLimit) { selectedFrameRateLimit = $0 }
            assignIfChanged(playlistBookmarks, to: config.playlistBookmarks ?? []) { playlistBookmarks = $0 }
            assignIfChanged(shufflePlaylist, to: config.shufflePlaylist) { shufflePlaylist = $0 }
            assignIfChanged(playlistRotationMinutes, to: config.playlistRotationMinutes) { playlistRotationMinutes = $0 }
            assignIfChanged(scheduleSlots, to: config.scheduleSlots ?? []) { scheduleSlots = $0 }
            if let preset = config.shaderPreset {
                assignIfChanged(selectedShaderPreset, to: preset) { selectedShaderPreset = $0 }
            }
            assignIfChanged(selectedWallpaperType, to: config.wallpaperType) { selectedWallpaperType = $0 }
            assignIfChanged(selectedWallpaperMode, to: config.wallpaperMode) { selectedWallpaperMode = $0 }
            assignIfChanged(htmlSource, to: config.htmlSource) { htmlSource = $0 }
            assignIfChanged(htmlConfig, to: config.htmlConfig ?? .default) { htmlConfig = $0 }
            assignIfChanged(hasPreviewSource, to: config.wallpaperType == .video && config.hasConfiguredVideoSource) {
                hasPreviewSource = $0
            }
            if config.wallpaperType != .video {
                assignIfChanged(lastPreviewPosterBookmarkData, to: nil) { lastPreviewPosterBookmarkData = $0 }
            }
            loadPreviewPosterIfNeeded()
        } else {
            assignIfChanged(playbackSpeed, to: 1.0) { playbackSpeed = $0 }
            assignIfChanged(selectedFitMode, to: .aspectFill) { selectedFitMode = $0 }
            assignIfChanged(selectedVideoDisplayMode, to: .perDisplay) { selectedVideoDisplayMode = $0 }
            assignIfChanged(selectedParticleEffect, to: .none) { selectedParticleEffect = $0 }
            assignIfChanged(effectConfig, to: .default) { effectConfig = $0 }
            assignIfChanged(particleDensity, to: 1.0) { particleDensity = $0 }
            assignIfChanged(setAsLockScreen, to: false) { setAsLockScreen = $0 }
            assignIfChanged(videoMuted, to: true) { videoMuted = $0 }
            assignIfChanged(videoVolume, to: 1.0) { videoVolume = $0 }
            assignIfChanged(selectedFrameRateLimit, to: .fps60) { selectedFrameRateLimit = $0 }
            assignIfChanged(playlistBookmarks, to: []) { playlistBookmarks = $0 }
            assignIfChanged(shufflePlaylist, to: false) { shufflePlaylist = $0 }
            assignIfChanged(playlistRotationMinutes, to: nil) { playlistRotationMinutes = $0 }
            assignIfChanged(scheduleSlots, to: []) { scheduleSlots = $0 }
            assignIfChanged(selectedWallpaperType, to: .video) { selectedWallpaperType = $0 }
            assignIfChanged(selectedWallpaperMode, to: .single) { selectedWallpaperMode = $0 }
            assignIfChanged(htmlSource, to: nil) { htmlSource = $0 }
            assignIfChanged(htmlConfig, to: .default) { htmlConfig = $0 }
            assignIfChanged(hasPreviewSource, to: screen.videoPlayer?.videoURL != nil) { hasPreviewSource = $0 }
            assignIfChanged(lastPreviewPosterBookmarkData, to: nil) { lastPreviewPosterBookmarkData = $0 }
            // Config was cleared (e.g. Reset Defaults): make sure the
            // poster / preview player cached on `previewController`
            // doesn't keep showing the old video frame after the
            // runtime session has already been torn down.
            previewController.cleanup()
            loadPreviewPosterIfNeeded()
        }
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
        guard ResourceUtilities.isSupportedVideoURL(url) else {
            errorMessage = "Choose a supported video file."
            showErrorAlert = true
            return
        }

        withAnimation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2))) { isLoading = true }
        cleanupPreviewPlayer()

        if let bookmarkData = ResourceUtilities.createVideoBookmark(for: url) {
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
    static let hitAreaWidth: CGFloat = 28

    let width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let onPreviewWidthChange: (CGFloat) -> Void
    let onCommitWidth: (CGFloat) -> Void

    private let handleWidth: CGFloat = 6
    private let handleHeight: CGFloat = 52

    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            Capsule()
                .fill(.regularMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isActive ? Color.primary.opacity(0.28) : Color.primary.opacity(0.12),
                            lineWidth: 0.75
                        )
                )
                .frame(width: handleWidth, height: handleHeight)
                .shadow(color: Color.black.opacity(0.08), radius: 5, x: 0, y: 2)
                .opacity(isActive ? 0.95 : 0.55)
        }
        .frame(width: Self.hitAreaWidth)
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: isActive)
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
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
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
