import SwiftUI
import UniformTypeIdentifiers

struct ScreenDetailView: View {
    var screen: Screen
    @Environment(ScreenManager.self) private var screenManager

    @State private var playbackSpeed: Double = 1.0
    @State private var selectedFitMode: VideoFitMode = .aspectFill
    @State private var isLoading: Bool = false
    private var wallpaperSessionSummary: WallpaperSessionSummary {
        screen.wallpaperSessionSummary
    }
    private var sessionStatusText: String {
        switch wallpaperSessionSummary.wallpaperType {
        case .html:
            return "HTML Active"
        case .metalShader:
            return "Shader Active"
        case .video:
            return wallpaperSessionSummary.activity == .active ? "Playing" : "Paused"
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
    @State private var showVideoImporter = false
    @State private var previewController = InspectorPreviewController()
    @State private var hasPreviewSource = false

    @State private var selectedWallpaperType: WallpaperType = .video
    @State private var selectedWallpaperMode: WallpaperMode = .single
    @State private var selectedParticleEffect: ParticleEffect = .none
    @State private var effectConfig = VideoEffectConfig.default
    @State private var selectedShaderPreset: MetalShaderPreset = .waves
    @State private var htmlContent: String = ""
    @State private var setAsLockScreen: Bool = false

    @State private var playlistBookmarks: [Data] = []
    @State private var shufflePlaylist: Bool = false
    @State private var playlistRotationMinutes: Int? = nil
    @State private var scheduleSlots: [ScheduleSlot] = []

    @State private var isDraggingOver = false
    @State private var screenPauseOnBattery: Bool = false
    @State private var lockScreenExtracted: Bool = false
    @State private var particleDensity: Double = 1.0
    @State private var selectedFrameRateLimit: FrameRateLimit = .fps60

    @AppStorage("Inspector.PlaylistExpanded") private var isPlaylistExpanded = false
    @AppStorage("Inspector.ScheduleExpanded") private var isScheduleExpanded = false
    @AppStorage("Inspector.EnvironmentExpanded") private var isEnvironmentExpanded = true
    @AppStorage("Inspector.ColorExpanded") private var isColorExpanded = false
    @AppStorage("Inspector.DisplayExpanded") private var isDisplayExpanded = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Header
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

            // MAIN CONTENT (Two Columns)
            // Disable implicit layout animation when switching wallpaper type —
            // the inspector's appear/disappear and the preview-area resize
            // would otherwise produce an unwanted stretch.
            HStack(spacing: 0) {
                // LEFT: Video Preview
                ZStack {
                    Color(NSColor.underPageBackgroundColor)

                    if selectedWallpaperType == .video {
                        if isLoading {
                            ScreenDetailLoadingView()
                        } else if hasPreviewSource || previewController.hasPreviewContent {
                            VStack(spacing: 16) {
                                VideoPreviewSection(
                                    previewController: previewController,
                                    hasPreviewSource: hasPreviewSource,
                                    selectedFitMode: selectedFitMode,
                                    startPreview: setupPreviewPlayer
                                )
                                // Locked 16:9 + max size: prevents preview aspect ratio from
                                // jumping when switching screens with different inspector content lengths.
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

                                    // Speed gets its own row so it doesn't compete with Fit
                                    // for horizontal space (the old HStack truncated the picker).
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
                            // Center preview + controls vertically. The previous Spacer(minLength:0)
                            // with alignment:.top left a large empty band below the controls.
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
                        HTMLWallpaperSection(screen: screen, htmlContent: $htmlContent)
                            .padding(24)
                    } else if selectedWallpaperType == .metalShader {
                        ShaderWallpaperSection(screen: screen, selectedShaderPreset: $selectedShaderPreset)
                            .padding(24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // RIGHT: Inspector ScrollView
                if selectedWallpaperType == .video {
                    ScrollView {
                        // GlassEffectContainer enables glass morphing between
                        // sibling cards and is more performant than rendering
                        // each glass surface independently.
                        GlassEffectContainer(spacing: 16) {
                            VStack(spacing: 16) {
                            // Mode picker: single capsule container with internal segments
                            // (matches the toolbar Wallpaper Type picker visually); the entire
                            // segment area is hit-testable, not just the text glyphs.
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
                            // Playlist Group
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
                            // Schedule Group
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

                            // Environment Group
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

                                        // Weather-Reactive toggle
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

                            // Color & Filters Group
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

                            // Display & Power Group
                            GroupBox {
                                CollapsibleSection(
                                    title: "Display & Power",
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

                                        SettingRow(icon: "bolt.slash", iconColor: .yellow, title: "Pause on Battery") {
                                            Toggle("", isOn: $screenPauseOnBattery)
                                                .labelsHidden()
                                                .toggleStyle(.switch)
                                                .onChange(of: screenPauseOnBattery) { _, newValue in
                                                    screenManager.updatePowerSettings(pauseOnBattery: newValue, for: screen)
                                                }
                                                .accessibilityLabel("Pause on battery")
                                                .accessibilityHint("Pauses wallpaper playback when running on battery power")
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
                    if newType == .video {
                        screenManager.switchToVideoWallpaper(for: screen)
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
        // React to background mutations (playlist rotation, schedule switch,
        // weather effects, power policy edits) so the inspector never shows
        // stale @State that would clobber the new config when the user
        // touches a control.
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
        .fileImporter(
            isPresented: $showVideoImporter,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie, .avi],
            allowsMultipleSelection: false
        ) { result in
            handleImporterResult(result)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
        } isTargeted: { targeted in
            isDraggingOver = targeted
        }
    }

    // MARK: - Drag and Drop
    private func handleDrop(urls: [URL]) -> Bool {
        defer { isDraggingOver = false }
        guard let videoURL = urls.first else { return false }
        handleSelectedFile(url: videoURL)
        return true
    }

    // MARK: - Helper Methods
    func setupPreviewPlayer() {
        guard let url = resolvePreviewVideoURL() else { return }
        previewController.startPlaybackPreview(from: url, syncTo: screen.videoPlayer?.player)
    }

    private func loadScreenConfiguration() {
        // Always reset transient feedback state when switching screens.
        lockScreenExtracted = false

        if let config = screenManager.getConfiguration(for: screen) {
            if playbackSpeed != config.playbackSpeed { playbackSpeed = config.playbackSpeed }
            if selectedFitMode != config.fitMode { selectedFitMode = config.fitMode }

            selectedParticleEffect = config.particleEffect
            effectConfig = config.effectConfig
            particleDensity = config.effectConfig.particleDensity
            setAsLockScreen = config.setAsLockScreen
            screenPauseOnBattery = config.pauseOnBattery
            selectedFrameRateLimit = config.frameRateLimit
            playlistBookmarks = config.playlistBookmarks ?? []
            shufflePlaylist = config.shufflePlaylist
            playlistRotationMinutes = config.playlistRotationMinutes
            scheduleSlots = config.scheduleSlots ?? []
            if let preset = config.shaderPreset { selectedShaderPreset = preset }
            selectedWallpaperType = config.wallpaperType
            selectedWallpaperMode = config.wallpaperMode
            htmlContent = config.htmlContent ?? ""
            hasPreviewSource = config.wallpaperType == .video && config.videoBookmarkData != nil
            loadPreviewPosterIfNeeded()
        } else {
            // No configuration — fall back to defaults so previously selected
            // values from another screen don't leak in.
            playbackSpeed = 1.0
            selectedFitMode = .aspectFill
            selectedParticleEffect = .none
            effectConfig = .default
            particleDensity = 1.0
            setAsLockScreen = false
            screenPauseOnBattery = false
            selectedFrameRateLimit = .fps60
            playlistBookmarks = []
            shufflePlaylist = false
            playlistRotationMinutes = nil
            scheduleSlots = []
            selectedWallpaperType = .video
            selectedWallpaperMode = .single
            htmlContent = ""
            hasPreviewSource = screen.videoPlayer?.videoURL != nil
            loadPreviewPosterIfNeeded()
        }
    }

    private func cleanupPreviewPlayer() {
        previewController.cleanup()
    }

    private func showFilePicker() {
        showVideoImporter = true
    }

    private func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
            handleSelectedFile(url: url)
        case .failure(let error):
            Logger.error("Video import failed: \(error.localizedDescription)", category: .fileAccess)
            errorMessage = "Failed to import video: \(error.localizedDescription)"
            showErrorAlert = true
        }
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
            // Refresh the persisted bookmark when macOS reports it as stale,
            // so subsequent launches don't keep re-resolving against drifted data.
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
