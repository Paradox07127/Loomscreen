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
    /// Resolved Wallpaper Engine origin metadata for the active wallpaper, or
    /// nil when the user picked content directly. Recomputed on every body
    /// evaluation so save/import flows propagate without local @State.
    private var wpeOrigin: WPEOrigin? {
        screenManager.getConfiguration(for: screen)?.wpeOrigin
    }

    private var sessionStatusText: String {
        switch wallpaperSessionSummary.wallpaperType {
        case .html:
            return "HTML Active"
        case .metalShader:
            return "Shader Active"
        case .video:
            return wallpaperSessionSummary.activity == .active ? "Playing" : "Paused"
        case .scene:
            return "Scene"
        case nil:
            return "Not configured"
        }
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
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var showClearConfirm = false
    @State private var previewController = InspectorPreviewController()
    @State private var hasPreviewSource = false

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
    @AppStorage("Inspector.DisplayExpanded") private var isDisplayExpanded = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 44, height: 44)
                    Image(systemName: "display").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(screen.name).font(.system(size: 18, weight: .semibold)).lineLimit(1)

                        Button(action: { screenManager.reloadWallpaperForScreen(screen) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Reload display content")
                        .accessibilityLabel("Reload display")
                        .accessibilityHint("Reloads the wallpaper content for this screen")
                    }
                    HStack(spacing: 8) {
                        InfoBadge(icon: "arrow.up.left.and.arrow.down.right", text: "\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                        InfoBadge(icon: "gauge.medium", text: "\(getScreenRefreshRate()) Hz")
                        if wallpaperSessionSummary.isConfigured {
                            HStack(spacing: 4) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundStyle(sessionStatusColor)
                                    .symbolEffect(.pulse, options: .repeat(.continuous), isActive: wallpaperSessionSummary.activity == .active)
                                Text(sessionStatusText).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer()

                Button {
                    showBookmarks = true
                } label: {
                    Label("Bookmarks", systemImage: "bookmark.fill")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .help("Saved video / HTML / shader shortcuts")
                .accessibilityLabel("Bookmarks")
                .popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
                    BookmarksPopover(screen: screen)
                        .environment(screenManager)
                }

                if selectedWallpaperType == .video {
                    HStack(spacing: 8) {
                        Button {
                            showFilePicker()
                        } label: {
                            Label("Select Video", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.regular)
                        .help("Choose a video file for this display")
                        .accessibilityLabel("Select video")
                        .accessibilityHint("Opens a file picker to choose a wallpaper video")

                        Button(role: .destructive) {
                            clearVideo()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                        .help("Remove wallpaper video")
                        .accessibilityLabel("Clear video")
                        .accessibilityHint("Removes the current wallpaper video from this screen")
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                ZStack {
                    Color(NSColor.underPageBackgroundColor)

                    if selectedWallpaperType == .video {
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
                                .frame(maxWidth: 720, maxHeight: 405)
                                .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)

                                VStack(spacing: 10) {
                                    HStack(spacing: 8) {
                                        ForEach(VideoFitMode.allCases) { mode in
                                            FitModeButton(mode: mode, isSelected: selectedFitMode == mode) {
                                                withAnimation(.snappy(duration: 0.2)) {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    dragHintOverlay
                        .animation(.smooth(duration: 0.2), value: isDraggingOver)
                }

                Divider()

                if selectedWallpaperType == .video {
                    ScrollView {
                        GlassEffectContainer(spacing: 16) {
                            VStack(spacing: 16) {
                            HStack(spacing: 0) {
                                ForEach(WallpaperMode.allCases) { mode in
                                    Button {
                                        withAnimation(.snappy(duration: 0.18)) {
                                            selectedWallpaperMode = mode
                                        }
                                        screenManager.updateWallpaperMode(mode, for: screen)
                                    } label: {
                                        Text(mode.label)
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
                                    .accessibilityLabel("\(mode.label) mode")
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
                                                    Text(effect.rawValue).tag(effect)
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(width: 110)
                                            .onChange(of: selectedParticleEffect) { _, newValue in
                                                screenManager.updateParticleEffect(newValue, for: screen)
                                            }
                                            .accessibilityLabel("Particle effect")
                                            .accessibilityValue(selectedParticleEffect.rawValue)
                                            .accessibilityHint("Choose a particle overlay effect")
                                            .help("Overlay particle effects on the wallpaper")
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
                                                        .accessibilityLabel("Particle density")
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
                                                .help("Adjust effects based on real-time weather conditions")
                                                .accessibilityLabel("Weather-reactive effects")
                                                .accessibilityHint("Automatically adjust particles and color based on real-time weather")
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

                            GroupBox {
                                CollapsibleSection(
                                    title: "Display",
                                    systemImage: "display.and.arrow.down",
                                    isExpanded: $isDisplayExpanded
                                ) {
                                    VStack(spacing: 8) {
                                        SettingRow(icon: "gauge.with.dots.needle.bottom.50percent", iconColor: .blue, title: "Frame Rate") {
                                            Picker("", selection: $selectedFrameRateLimit) {
                                                ForEach(FrameRateLimit.allCases) { limit in
                                                    Text(limit.description).tag(limit)
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(width: 110)
                                            .onChange(of: selectedFrameRateLimit) { _, newValue in
                                                screenManager.updateFrameRateLimit(newValue, for: screen)
                                            }
                                            .accessibilityLabel("Frame rate limit")
                                            .accessibilityValue(selectedFrameRateLimit.description)
                                        }

                                        Divider()

                                        SettingRow(
                                            icon: videoMuted ? "speaker.slash" : "speaker.wave.2",
                                            iconColor: videoMuted ? .secondary : .blue,
                                            title: "Audio",
                                            subtitle: videoMuted
                                                ? "Muted (default)"
                                                : "Routed through system output"
                                        ) {
                                            Toggle("", isOn: Binding(get: { !videoMuted }, set: { videoMuted = !$0 }))
                                                .labelsHidden()
                                                .toggleStyle(.switch)
                                                .onChange(of: videoMuted) { _, newValue in
                                                    screenManager.updateMuted(newValue, for: screen)
                                                }
                                                .accessibilityLabel("Video audio")
                                                .accessibilityHint("When off, audio tracks are disabled entirely so macOS does not engage the audio engine")
                                        }

                                        Divider()

                                        SettingRow(icon: "photo.on.rectangle", iconColor: .blue, title: "Desktop Picture") {
                                            HStack(spacing: 6) {
                                                if lockScreenExtracted {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundStyle(.green)
                                                        .transition(.scale.combined(with: .opacity))
                                                }
                                                Toggle("", isOn: $setAsLockScreen)
                                                    .labelsHidden()
                                                    .toggleStyle(.switch)
                                                    .onChange(of: setAsLockScreen) { _, newValue in
                                                        screenManager.updateSetAsDesktopPicture(newValue, for: screen)
                                                        if newValue {
                                                            screenManager.extractLockScreenFrame(for: screen)
                                                            withAnimation(.snappy(duration: 0.25)) { lockScreenExtracted = true }
                                                            Task {
                                                                try? await Task.sleep(for: .seconds(2))
                                                                withAnimation(.snappy(duration: 0.25)) { lockScreenExtracted = false }
                                                            }
                                                        }
                                                    }
                                                    .accessibilityLabel("Set current frame as desktop picture")
                                                    .accessibilityHint("Captures the currently visible video frame and uses it as the macOS desktop picture")
                                                    .help("Apply the current video frame as the desktop picture")
                                            }
                                        }
                                    }
                                }
                            }
                            .groupBoxStyle(ContainerGroupBoxStyle())
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                    }
                    .frame(width: 320)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipped()
                }
            }
            .transaction(value: selectedWallpaperType) { $0.animation = nil }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Wallpaper Type", selection: $selectedWallpaperType) {
                    ForEach(WallpaperType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Wallpaper type")
                .accessibilityHint("Choose between video, HTML, or Metal shader wallpaper")
                .onChange(of: selectedWallpaperType) { _, newType in
                    switch newType {
                    case .video:
                        screenManager.switchToVideoWallpaper(for: screen)
                    case .html:
                        screenManager.switchToHTMLWallpaper(for: screen)
                    case .metalShader:
                        break // shader picker drives its own activation
                    case .scene:
                        break // Scene tab content lands in Day 4; Day 1+2 only register the segment.
                    }
                }
            }
        }
        .onAppear { loadScreenConfiguration() }
        .onDisappear { cleanupPreviewPlayer() }
        .onChange(of: screen.id) {
            cleanupPreviewPlayer()
            loadScreenConfiguration()
        }
        // Keep inspector state aligned with background automation.
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
            Text("Are you sure you want to remove this video? This will delete all configuration for this screen.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
        } isTargeted: { targeted in
            isDraggingOver = targeted
        }
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

    private var dragHintSubtitle: String {
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
            loadPreviewPosterIfNeeded()
        }
    }

    private func cleanupPreviewPlayer() {
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
        panel.prompt = "Use as Wallpaper"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        handleSelectedFile(url: url)
    }

    private func handleSelectedFile(url: URL) {
        withAnimation(.smooth(duration: 0.2)) { isLoading = true }
        cleanupPreviewPlayer()

        if let bookmarkData = ResourceUtilities.createBookmark(for: url) {
            hasPreviewSource = true
            previewController.startPlaybackPreview(from: url, syncTo: nil)
            screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
        } else {
            errorMessage = "Error creating secure bookmark. Please try selecting a different video file."
            showErrorAlert = true
        }

        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.smooth(duration: 0.2)) { isLoading = false }
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
        guard previewController.player == nil,
              let url = resolvePreviewVideoURL() else { return }
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
}
