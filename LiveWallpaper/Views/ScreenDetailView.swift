import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct ScreenDetailView: View {
    var screen: Screen
    @Environment(ScreenManager.self) private var screenManager

    @State private var playbackSpeed: Double = 1.0
    @State private var selectedFitMode: VideoFitMode = .aspectFill
    @State private var isLoading: Bool = false
    private var isPlayerPlaying: Bool {
        _ = screen.playbackStateVersion
        return screen.videoPlayer?.isPlaying ?? false
    }
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var currentVideoPosition: Double = 0
    @State private var videoDuration: Double = 1.0

    @State private var selectedWallpaperType: WallpaperType = .video
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
    @State private var showColorAdjustments = false
    @State private var screenPauseOnBattery: Bool = false
    @State private var lockScreenExtracted: Bool = false
    @State private var particleDensity: Double = 1.0
    @State private var selectedFrameRateLimit: FrameRateLimit = .fps60

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
                        
                        Button(action: { screenManager.reloadVideoForScreen(screen) }) {
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
                        if let player = screen.videoPlayer {
                            HStack(spacing: 4) {
                                Circle().fill(player.isPlaying ? Color.green : Color.orange).frame(width: 6, height: 6)
                                Text(player.isPlaying ? "Playing" : "Paused").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer()
                
                if selectedWallpaperType == .video {
                    HStack(spacing: 12) {
                        Button(action: showFilePicker) {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.badge.plus")
                                Text("Select Video")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Choose a video file for this display")
                        .accessibilityLabel("Select video")
                        .accessibilityHint("Opens a file picker to choose a wallpaper video")
                        
                        Button(action: clearVideo) {
                            Image(systemName: "trash")
                                .padding(8)
                                .background(Color.red.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .help("Remove wallpaper video")
                        .accessibilityLabel("Clear video")
                        .accessibilityHint("Removes the current wallpaper video from this screen")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            
            Divider()
            
            // MAIN CONTENT (Two Columns)
            HStack(spacing: 0) {
                // LEFT: Video Preview
                ZStack {
                    Color(NSColor.underPageBackgroundColor)
                    
                    if selectedWallpaperType == .video {
                        if isLoading {
                            loadingView
                        } else if screen.videoPlayer != nil || screen.previewPlayer != nil {
                            VStack(spacing: 20) {
                                Spacer()
                                videoPreviewSection
                                    .aspectRatio(16/9, contentMode: .fit)
                                    .frame(maxWidth: 640)
                                    .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
                                
                                HStack(spacing: 24) {
                                    HStack(spacing: 12) {
                                        ForEach(VideoFitMode.allCases) { mode in
                                            FitModeButton(mode: mode, isSelected: selectedFitMode == mode, action: {
                                                selectedFitMode = mode
                                                screenManager.updateFitMode(mode, for: screen)
                                            })
                                        }
                                    }
                                    
                                    Divider()
                                        .frame(height: 24)
                                    
                                    HStack(spacing: 12) {
                                        Text("Speed")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.secondary)
                                        SegmentedSpeedPicker(selectedSpeed: $playbackSpeed) { speed in
                                            screen.videoPlayer?.setPlaybackSpeed(speed)
                                            screenManager.updatePlaybackSpeed(speed, for: screen)
                                        }
                                        .frame(width: 180)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color(NSColor.windowBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                
                                Spacer()
                            }
                            .padding(24)
                        } else {
                            enhancedEmptyStateView
                                .padding(24)
                        }
                    } else if selectedWallpaperType == .html {
                        HTMLWallpaperSection(screen: screen, htmlContent: $htmlContent)
                            .padding(8)
                    } else if selectedWallpaperType == .metalShader {
                        ShaderWallpaperSection(screen: screen, selectedShaderPreset: $selectedShaderPreset)
                            .padding(8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Divider()
                
                // RIGHT: Inspector ScrollView
                if selectedWallpaperType == .video {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Playlist Group
                            GroupBox {
                                PlaylistSection(
                                    playlistBookmarks: $playlistBookmarks,
                                    shufflePlaylist: $shufflePlaylist,
                                    rotationMinutes: $playlistRotationMinutes,
                                    screen: screen,
                                    screenManager: screenManager
                                )
                                .padding(8)
                            } label: {
                                Label("Playlist", systemImage: "list.bullet")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            // Schedule Group
                            GroupBox {
                                ScheduleSection(
                                    scheduleSlots: $scheduleSlots,
                                    screen: screen,
                                    screenManager: screenManager
                                )
                                .padding(8)
                            } label: {
                                Label("Schedule", systemImage: "clock")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            // Effects Group
                            GroupBox {
                                VStack(spacing: 14) {
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
                                    
                                    // Note: macOS has no public lock screen wallpaper API.
                                    // This applies the current frame as the desktop picture
                                    // via NSWorkspace.setDesktopImageURL.
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
                                                        withAnimation { lockScreenExtracted = true }
                                                        Task {
                                                            try? await Task.sleep(for: .seconds(2))
                                                            withAnimation { lockScreenExtracted = false }
                                                        }
                                                    }
                                                }
                                                .accessibilityLabel("Set current frame as desktop picture")
                                                .accessibilityHint("Captures the currently visible video frame and uses it as the macOS desktop picture")
                                                .help("Apply the current video frame as the desktop picture")
                                        }
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
                                        WeatherStatusBadge(weatherService: screenManager.weatherService)
                                    }

                                    Divider()

                                    ColorAdjustmentsView(effectConfig: $effectConfig, screen: screen, screenManager: screenManager)
                                }
                                .padding(8)
                            } label: {
                                Label("Effects", systemImage: "wand.and.stars")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            // Frame Rate Group
                            GroupBox {
                                VStack(spacing: 14) {
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
                                }
                                .padding(8)
                            } label: {
                                Label("Frame Rate", systemImage: "gauge.with.dots.needle.bottom.50percent")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                    }
                    .frame(width: 280)
                    .background(Color(NSColor.windowBackgroundColor))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Wallpaper Type", selection: $selectedWallpaperType) {
                    ForEach(WallpaperType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .accessibilityLabel("Wallpaper type")
                .accessibilityHint("Choose between video, HTML, or Metal shader wallpaper")
                .onChange(of: selectedWallpaperType) { _, newType in
                    if newType == .video {
                        screenManager.switchToVideoWallpaper(for: screen)
                    }
                }
            }
        }
        .task(id: screen.id) {
            while !Task.isCancelled {
                if let player = screen.previewPlayer {
                    let time = player.currentTime().seconds
                    if !time.isNaN && !time.isInfinite { currentVideoPosition = time }
                    let dur = player.currentItem?.duration.seconds ?? 0
                    if !dur.isNaN && !dur.isInfinite && dur > 0 { videoDuration = dur }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onAppear { loadScreenConfiguration() }
        .onChange(of: screen.id) { loadScreenConfiguration() }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: { Text(errorMessage) }
        .onDrop(of: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi], isTargeted: $isDraggingOver) { providers in
            return handleDrop(providers: providers)
        }
    }

    // MARK: - Drag and Drop
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.movie.identifier, options: nil) { item, error in
                let resolvedURL: URL?
                if let data = item as? Data { resolvedURL = URL(dataRepresentation: data, relativeTo: nil) }
                else if let itemURL = item as? URL { resolvedURL = itemURL }
                else { resolvedURL = nil }
                
                let errorDesc = error?.localizedDescription
                Task { @MainActor in
                    if let errorDesc {
                        self.errorMessage = "Failed to load dropped file: \(errorDesc)"
                        self.showErrorAlert = true
                        return
                    }
                    if let videoURL = resolvedURL { self.handleSelectedFile(url: videoURL) }
                }
            }
            return true
        }
        return false
    }

    // MARK: - UI Components
    private var loadingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.bottom, 8)
            Text("Loading video...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private var enhancedEmptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: isDraggingOver ? "arrow.down.doc.fill" : "film")
                .font(.system(size: 60))
                .foregroundStyle(isDraggingOver ? Color.green : Color.accentColor)
                .padding(.bottom, 10)
                .animation(.easeInOut(duration: 0.2), value: isDraggingOver)

            Text(isDraggingOver ? "Drop Video Here" : "No Video Selected")
                .font(.title2)
                .fontWeight(.medium)
                .animation(.easeInOut(duration: 0.2), value: isDraggingOver)

            if !isDraggingOver {
                Button(action: showFilePicker) {
                    Label("Select Video File", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 24)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .shadow(color: Color.accentColor.opacity(0.3), radius: 5, x: 0, y: 2)
                .padding(.top, 10)
                .accessibilityLabel("Select video file")
                .accessibilityHint("Opens a file picker to choose a wallpaper video")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.windowBackgroundColor).opacity(isDraggingOver ? 0.8 : 0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDraggingOver ? Color.green : Color.clear,
                    style: StrokeStyle(lineWidth: 3, dash: isDraggingOver ? [] : [8])
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isDraggingOver)
    }
    
    private var videoPreviewSection: some View {
        ZStack(alignment: .bottom) {
            if let player = screen.previewPlayer {
                CustomVideoPlayer(player: player, fitMode: selectedFitMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
                
                // Top Overlay for Video Info
                VStack {
                    HStack {
                        VideoInformationOverlay(player: player)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(16)
                
                // Bottom Overlay for Playback controls
                VStack(spacing: 8) {
                    Slider(
                        value: $currentVideoPosition,
                        in: 0...max(1, videoDuration),
                        onEditingChanged: { editing in
                            if !editing, let player = screen.previewPlayer {
                                player.seek(to: CMTime(seconds: currentVideoPosition, preferredTimescale: 600))
                            }
                        }
                    )
                    .padding(.horizontal, 24)
                    .controlSize(.small)
                    .accessibilityLabel("Video position")
                    .accessibilityValue("\(FormatUtils.formatDuration(currentVideoPosition)) of \(FormatUtils.formatDuration(videoDuration))")
                    .accessibilityHint("Scrub through the video timeline")
                    
                    HStack {
                        Text(FormatUtils.formatDuration(currentVideoPosition))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                        
                        Spacer()
                        
                        PlaybackToggleButton(isPlaying: isPlayerPlaying) {
                            togglePlayback()
                        }
                        .foregroundStyle(.white)
                        
                        Spacer()
                        
                        Text(FormatUtils.formatDuration(videoDuration))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                }
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.black.opacity(0), Color.black.opacity(0.8)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
            } else if screen.videoPlayer != nil {
                VStack(spacing: 14) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Preview unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Reload Preview") { setupPreviewPlayer() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityLabel("Reload preview")
                        .accessibilityHint("Attempts to reload the video preview")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(.separatorColor), lineWidth: 1))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            togglePlayback()
        }
    }
    
    // MARK: - View Components
    struct InfoBadge: View {
        let icon: String
        let text: String
        var body: some View {
            HStack(spacing: 2) {
                Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    struct SegmentedSpeedPicker: View {
        @Binding var selectedSpeed: Double
        var onChange: (Double) -> Void
        private let speeds: [Double] = [0.5, 0.75, 1.0, 1.5, 2.0]
        
        var body: some View {
            HStack(spacing: 2) {
                ForEach(speeds, id: \.self) { speed in
                    Button(action: {
                        selectedSpeed = speed
                        onChange(speed)
                    }) {
                        Text(speed == 1.0 ? "1.0" : "\(String(format: "%.1f", speed))x")
                            .font(.system(size: 12))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .background(selectedSpeed == speed ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(selectedSpeed == speed ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                    .help("Playback speed: \(String(format: "%.1f", speed))x")
                    .accessibilityLabel("Speed \(String(format: "%.1f", speed))x")
                    .accessibilityHint(selectedSpeed == speed ? "Currently selected" : "Set playback speed to \(String(format: "%.1f", speed))x")
                }
            }
        }
    }
    
    struct PlaybackToggleButton: View {
        var isPlaying: Bool
        var action: () -> Void
        
        var body: some View {
            Button(action: action) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .resizable()
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Pause" : "Play")
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityHint(isPlaying ? "Pauses video playback" : "Resumes video playback")
        }
    }
    
    struct FitModeButton: View {
        let mode: VideoFitMode
        let isSelected: Bool
        let action: () -> Void
        
        var body: some View {
            Button(action: action) {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                            .frame(width: 36, height: 36)
                        Image(systemName: mode.iconName)
                            .font(.system(size: 14))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.gray)
                    }
                    Text(mode.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .help(fitModeTooltip)
            .accessibilityLabel("\(mode.rawValue) fit mode")
            .accessibilityHint(isSelected ? "Currently selected" : "Tap to switch to \(mode.rawValue) fit mode")
        }

        private var fitModeTooltip: String {
            switch mode {
            case .aspectFill: return "Fill: crop to fill screen"
            case .aspectFit: return "Fit: show entire video"
            case .stretch: return "Stretch: distort to fill"
            }
        }
    }

    struct ColorAdjustmentsView: View {
        @Binding var effectConfig: VideoEffectConfig
        var screen: Screen
        var screenManager: ScreenManager
        
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 26, height: 26)
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    Text("Color Adjustments")
                        .font(.system(size: 13, weight: .medium))
                }
                
                VStack(spacing: 12) {
                    effectSlider(title: "Blur", value: $effectConfig.blurRadius, in: 0...30, format: "%.0f")
                    effectSlider(title: "Brightness", value: $effectConfig.brightness, in: -0.5...0.5, format: "%.2f")
                    effectSlider(title: "Saturation", value: $effectConfig.saturation, in: 0...2, format: "%.1f")
                    effectSlider(title: "Warmth", value: $effectConfig.warmth, in: 2500...8000, format: "%.0f")
                    effectSlider(title: "Vignette", value: $effectConfig.vignetteIntensity, in: 0...5, format: "%.1f")
                    
                    Divider()
                    
                    HStack {
                        Text("Auto warm tint by time of day")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Toggle("", isOn: $effectConfig.autoTimeTint)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .help("Automatically adjust color temperature by time of day")
                            .accessibilityLabel("Auto warm tint")
                            .accessibilityHint("Automatically adjusts color warmth based on time of day")
                    }

                    Divider()

                    HStack {
                        Spacer()
                        Button(action: {
                            effectConfig = .default
                            screenManager.updateEffectConfig(effectConfig, for: screen)
                        }) {
                            Label("Reset to Default", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Reset all color adjustments to default values")
                        Spacer()
                    }
                }
            }
            .onChange(of: effectConfig) { _, _ in
                screenManager.updateEffectConfig(effectConfig, for: screen)
            }
        }
        
        private func effectSlider(title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: String) -> some View {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 13))
                    .frame(width: 70, alignment: .leading)

                Slider(value: value, in: range)
                    .controlSize(.small)
                    .accessibilityLabel(title)
                    .accessibilityValue(String(format: format, value.wrappedValue))

                TextField(
                    "",
                    value: Binding(
                        get: { value.wrappedValue },
                        set: { newVal in
                            value.wrappedValue = min(max(newVal, range.lowerBound), range.upperBound)
                        }
                    ),
                    format: .number
                )
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 35, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
            }
        }
    }

    // MARK: - Helper Methods
    func setupPreviewPlayer() {
        guard screen.previewPlayer == nil else { return }

        if let config = screenManager.getConfiguration(for: screen),
           config.wallpaperType == .video {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: config.videoBookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                // Retain the scope for the lifetime of the preview player —
                // AVFoundation reads pixel data lazily and a released scope
                // would cause the preview to fail on subsequent access.
                screen.retainPreviewSecurityScope(url)

                let asset = AVURLAsset(url: url)
                let playerItem = AVPlayerItem(asset: asset)
                playerItem.preferredForwardBufferDuration = 5.0

                let previewPlayer = AVPlayer(playerItem: playerItem)
                previewPlayer.volume = 0
                previewPlayer.automaticallyWaitsToMinimizeStalling = true
                screen.previewPlayer = previewPlayer
            } catch { }
        } else if let videoPlayer = screen.videoPlayer, let videoURL = videoPlayer.videoURL {
            screen.retainPreviewSecurityScope(videoURL)
            let asset = AVURLAsset(url: videoURL)
            let playerItem = AVPlayerItem(asset: asset)
            let previewPlayer = AVPlayer(playerItem: playerItem)
            previewPlayer.volume = 0
            screen.previewPlayer = previewPlayer
        }
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
            htmlContent = config.htmlContent ?? ""
            setupPreviewPlayer()
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
            htmlContent = ""
        }
    }
    
    private func cleanupPreviewPlayer() {
        if let previewPlayer = screen.previewPlayer {
            previewPlayer.pause()
            screen.previewPlayer = nil
        }
    }
    
    private func showFilePicker() {
        let panel = ResourceUtilities.configureVideoOpenPanel()
        panel.begin { response in
            if response == .OK, let url = panel.url {
                SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
                handleSelectedFile(url: url)
            }
        }
    }
    
    private func handleSelectedFile(url: URL) {
        withAnimation { isLoading = true }
        cleanupPreviewPlayer()

        // Retain the scope for the preview player's lifetime; ScreenManager.setVideo
        // will start its own scope for the wallpaper window separately.
        screen.retainPreviewSecurityScope(url)
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let previewPlayer = AVPlayer(playerItem: playerItem)
        previewPlayer.volume = 0

        Task { @MainActor in
            self.screen.previewPlayer = previewPlayer
            previewPlayer.play()
        }

        if let bookmarkData = ResourceUtilities.createBookmark(for: url) {
            screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
        } else {
            errorMessage = "Error creating secure bookmark. Please try selecting a different video file."
            showErrorAlert = true
        }

        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation { isLoading = false }
        }
    }
    
    private func clearVideo() {
        let alert = NSAlert()
        alert.messageText = "Clear Wallpaper Video"
        alert.informativeText = "Are you sure you want to remove this video? This will delete all configuration for this screen."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Video")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            cleanupPreviewPlayer()
            screenManager.clearVideoForScreen(screen)
        }
    }
    
    private func togglePlayback() {
        if let player = screen.videoPlayer {
            if player.isPlaying {
                player.pause()
            } else {
                player.play()
            }
        }
    }
    
    private func getScreenRefreshRate() -> Int {
        screenManager.getScreenRefreshRate(for: screen.id)
    }
}

// MARK: - Weather Status Badge

struct WeatherStatusBadge: View {
    var weatherService: WeatherReactiveService

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: weatherIcon)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 1) {
                if let condition = weatherService.currentCondition {
                    Text(condition.rawValue.capitalized)
                        .font(.system(size: 11, weight: .medium))
                } else {
                    Text(weatherService.locationStatus.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let error = weatherService.lastError {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            if weatherService.currentParticleEffect != .none {
                Image(systemName: weatherService.currentParticleEffect.iconName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Weather status: \(weatherService.currentCondition?.rawValue ?? "loading")")
    }

    private var weatherIcon: String {
        switch weatherService.locationStatus {
        case .available: return "cloud.sun.fill"
        case .fetching: return "arrow.triangle.2.circlepath"
        case .denied: return "location.slash"
        case .error: return "exclamationmark.triangle"
        default: return "cloud.fill"
        }
    }

    private var statusColor: Color {
        switch weatherService.locationStatus {
        case .available: return .cyan
        case .fetching: return .orange
        case .denied: return .red
        case .error: return .red
        default: return .secondary
        }
    }
}