import SwiftUI
import AVKit
import Combine
import UniformTypeIdentifiers

struct ScreenDetailView: View {
    @ObservedObject var screen: Screen
    @EnvironmentObject private var screenManager: ScreenManager

    @State private var playbackSpeed: Double = 1.0
    @State private var selectedFitMode: VideoFitMode = .aspectFill
    @State private var isLoading: Bool = false
    @State private var isPlayerPlaying: Bool = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var currentVideoPosition: Double = 0
    @State private var videoDuration: Double = 1.0

    // Effects & new feature states
    @State private var selectedWallpaperType: WallpaperType = .video
    @State private var selectedParticleEffect: ParticleEffect = .none
    @State private var effectConfig = VideoEffectConfig.default
    @State private var selectedShaderPreset: MetalShaderPreset = .waves
    @State private var htmlContent: String = ""
    @State private var setAsLockScreen: Bool = false

    // Timer management
    @State private var playbackStateTimer: Timer?
    @State private var videoProgressTimer: Timer?

    // Drag and drop
    @State private var isDraggingOver = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 16) {
                    displayHeader

                    // Wallpaper type picker — always visible
                    wallpaperTypePicker

                    if selectedWallpaperType == .video {
                        if isLoading {
                            loadingView
                        } else if screen.videoPlayer != nil || screen.previewPlayer != nil {
                            VStack(spacing: 16) {
                                videoPreviewSection
                                    .frame(minHeight: 280, maxHeight: 380)

                                HStack(alignment: .top, spacing: 16) {
                                    playbackControlsSection
                                        .frame(maxWidth: .infinity)
                                    videoOptionsSection
                                        .frame(maxWidth: .infinity)
                                }

                                effectsSection
                            }
                        } else {
                            enhancedEmptyStateView
                        }
                    } else if selectedWallpaperType == .html {
                        htmlWallpaperSection
                    } else if selectedWallpaperType == .metalShader {
                        shaderWallpaperSection
                    }
                }
                .padding(20)
                .animation(.easeInOut(duration: 0.15), value: isLoading)
            }
        }
        .background(.clear)
        .onAppear {
            loadScreenConfiguration()
            startTimers()
        }
        .onDisappear {
            stopTimers()
        }
        .onChange(of: screen.id) { _ in
            // Reset state when switching between screens
            stopTimers()
            loadScreenConfiguration()
            startTimers()
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onDrop(of: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi], isTargeted: $isDraggingOver) { providers in
            return handleDrop(providers: providers)
        }
    }

    // MARK: - Drag and Drop

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Handle file URLs
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.movie.identifier, options: nil) { item, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self.errorMessage = "Failed to load dropped file: \(error.localizedDescription)"
                        self.showErrorAlert = true
                        return
                    }

                    var url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let itemURL = item as? URL {
                        url = itemURL
                    }

                    if let videoURL = url {
                        self.handleSelectedFile(url: videoURL)
                    }
                }
            }
            return true
        }

        return false
    }

    // MARK: - Timer Management

    private func startTimers() {
        // Playback state observer timer
        playbackStateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if let videoPlayer = screen.videoPlayer {
                let currentPlaying = videoPlayer.isPlaying
                if isPlayerPlaying != currentPlaying {
                    withAnimation {
                        isPlayerPlaying = currentPlaying
                    }
                }
            }
        }

        // Video progress observer timer
        videoProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if let player = screen.previewPlayer {
                let currentTime = player.currentTime().seconds
                if !currentTime.isNaN && !currentTime.isInfinite {
                    currentVideoPosition = currentTime
                }

                let duration = player.currentItem?.duration.seconds ?? 0
                if !duration.isNaN && !duration.isInfinite && duration > 0 {
                    videoDuration = duration
                }
            }
        }
    }

    private func stopTimers() {
        playbackStateTimer?.invalidate()
        playbackStateTimer = nil
        videoProgressTimer?.invalidate()
        videoProgressTimer = nil
    }
    // MARK: - UI Components
    
    private var displayHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            // Display icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 50, height: 50)
                Image(systemName: "display")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
            }
            
            // Display information
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.name)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                
                HStack(spacing: 10) {
                    // Resolution
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Refresh rate
                    HStack(spacing: 2) {
                        Image(systemName: "gauge.medium")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(getScreenRefreshRate()) Hz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Playback status indicator
                    if let player = screen.videoPlayer {
                        HStack(spacing: 2) {
                            Circle()
                                .fill(player.isPlaying ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(player.isPlaying ? "Playing" : "Paused")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            Spacer()
            
            // Reload button
            Button(action: {
                screenManager.reloadVideoForScreen(screen)
            }) {
                Label("Reload", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Reload video for this display")
        }
        .padding(.bottom, 10)
    }
    
    private var loadingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.bottom, 8)
            
            Text("Loading video...")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("This may take a moment depending on the file size")
                .font(.subheadline)
                .foregroundStyle(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(Color(colorScheme == .dark ? NSColor.darkGray : NSColor.lightGray).opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .transition(.opacity)
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

            Text(isDraggingOver ? "Release to set as wallpaper" : "Drag and drop a video file or click to browse")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
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

                Text("Supported formats: MP4, MOV, M4V, AVI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: 400)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(colorScheme == .dark ? NSColor.darkGray : NSColor.lightGray).opacity(isDraggingOver ? 0.2 : 0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDraggingOver ? Color.green : Color.clear,
                    style: StrokeStyle(lineWidth: 3, dash: isDraggingOver ? [] : [8])
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isDraggingOver)
        .transition(.opacity)
    }
    
    private var videoPreviewSection: some View {
        VStack(spacing: 0) {
            if let player = screen.previewPlayer {
                // Modernized video display with controls
                ZStack(alignment: .bottom) {
                    // Video display with improved styling
                    // In your videoPreviewSection:
                    CustomVideoPlayer(player: player, fitMode: selectedFitMode)
                        .aspectRatio(16/9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(.separatorColor), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                    // Add tap gesture to toggle play/pause
                        .onTapGesture(count: 1) {
                            togglePlayback()
                        }
                    
                    // Simplified overlay controls
                    VStack(spacing: 8) {
                        // Progress slider
                        Slider(
                            value: $currentVideoPosition,
                            in: 0...max(1, videoDuration),
                            onEditingChanged: { editing in
                                if !editing, let player = screen.previewPlayer {
                                    player.seek(to: CMTime(seconds: currentVideoPosition, preferredTimescale: 600))
                                }
                            }
                        )
                        .padding(.horizontal, 16)
                        
                        // Time display
                        HStack {
                            Text(FormatUtils.formatDuration(currentVideoPosition))
                                .font(.system(size: 11))
                                .foregroundStyle(.white)
                            
                            Spacer()
                            
                            Text(FormatUtils.formatDuration(videoDuration))
                                .font(.system(size: 11))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                    }
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.black.opacity(0), Color.black.opacity(0.7)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                }
                
                // Compact video information
                VideoInformationView(player: player, screenRefreshRate: getScreenRefreshRate())
                    .padding(.top, 8)
                    .padding(.horizontal, 2) // Reduce padding to save space
            } else if screen.videoPlayer != nil {
                // Display a cleaner message when preview is unavailable
                VStack(spacing: 14) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    
                    Text("Video is playing as wallpaper")
                        .font(.headline)
                    
                    Text("Preview unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Button("Reload Preview") {
                        setupPreviewPlayer()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small) // Smaller button to save space
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 280)
                .background(Color.gray.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(.separatorColor), lineWidth: 1)
                )
            }
        }
    }
    
    private var playbackControlsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                // Header with integrated play/pause button
                HStack {
                    Label("Playback Controls", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    
                    Spacer()
                    
                    PlaybackToggleButton(isPlaying: isPlayerPlaying) {
                        togglePlayback()
                    }
                }
                
                Divider()
                
                // Playback speed control with compact layout
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Speed")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Spacer()
                        
                        Text(String(format: "%.1fx", playbackSpeed))
                            .font(.system(size: 13))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    
                    // Speed slider
                    HStack(spacing: 8) {
                        Text("0.5x")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        Slider(value: $playbackSpeed, in: 0.5...2.0, step: 0.1)
                            .onChange(of: playbackSpeed) { oldValue, newValue in
                                if oldValue != newValue {
                                    screen.videoPlayer?.setPlaybackSpeed(newValue)
                                    screenManager.updatePlaybackSpeed(newValue, for: screen)
                                }
                            }
                        
                        Text("2.0x")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Speed presets as a compact segmented control
                    SegmentedSpeedPicker(selectedSpeed: $playbackSpeed) { speed in
                        screen.videoPlayer?.setPlaybackSpeed(speed)
                        screenManager.updatePlaybackSpeed(speed, for: screen)
                    }
                    .padding(.top, 2)
                }
                
                Divider()
                
                // File actions in a row
                HStack(spacing: 12) {
                    Button(action: showFilePicker) {
                        Label("Change Video", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button(action: clearVideo) {
                        Label("Remove", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                }
                .padding(.top, 2)
            }
            .padding(14)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
    
    // New segmented control for speed presets
    struct SegmentedSpeedPicker: View {
        @Binding var selectedSpeed: Double
        var onChange: (Double) -> Void
        
        private let speeds: [Double] = [0.5, 0.75, 1.0, 1.5, 2.0]
        
        var body: some View {
            HStack(spacing: 4) {
                ForEach(speeds, id: \.self) { speed in
                    Button(action: {
                        selectedSpeed = speed
                        onChange(speed)
                    }) {
                        Text(speed == 1.0 ? "1.0" : "\(String(format: "%.1f", speed))x")
                            .font(.system(size: 11))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .background(selectedSpeed == speed ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(selectedSpeed == speed ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                }
            }
        }
    }
    
    // Improved play/pause toggle button
    struct PlaybackToggleButton: View {
        var isPlaying: Bool
        var action: () -> Void
        
        var body: some View {
            Button(action: action) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Pause" : "Play")
        }
    }
    
    private var videoOptionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Video Options", systemImage: "rectangle.3.group")
                    .font(.headline)
                
                Divider()
                
                // Video fit mode with visual indicators
                VStack(alignment: .leading, spacing: 10) {
                    Text("Video Fit Mode")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    // Visual fit mode selector
                    HStack(spacing: 10) {
                        ForEach(VideoFitMode.allCases) { mode in
                            FitModeButton(
                                mode: mode,
                                isSelected: selectedFitMode == mode,
                                action: {
                                    selectedFitMode = mode
                                    screenManager.updateFitMode(mode, for: screen)
                                }
                            )
                        }
                    }
                    
                    // Description
                    Text(selectedFitMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                
                Divider()
                
                // Frame rate control
                if let player = screen.videoPlayer, player.videoFrameRate > 0 {
                    FrameRateControlView(screen: screen)
                        .frame(maxHeight: 120) // Limit height to save space
                } else {
                    HStack {
                        Image(systemName: "speedometer")
                            .foregroundStyle(.secondary)
                        
                        Text("Frame rate information unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(14)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
    
    // New compact fit mode button component
    struct FitModeButton: View {
        let mode: VideoFitMode
        let isSelected: Bool
        let action: () -> Void
        
        var body: some View {
            Button(action: action) {
                VStack(spacing: 6) {
                    // Icon with background
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: mode.iconName)
                            .font(.system(size: 16))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.gray)
                    }
                    
                    // Label
                    Text(mode.rawValue)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Effects Section

    private var effectsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Effects & Overlays", systemImage: "wand.and.stars")
                    .font(.headline)

                Divider()

                // Particle Effect Picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Particle Overlay")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Picker("Particle", selection: $selectedParticleEffect) {
                        ForEach(ParticleEffect.allCases) { effect in
                            Label(effect.rawValue, systemImage: effect.iconName)
                                .tag(effect)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedParticleEffect) { _, newValue in
                        updateParticleEffect(newValue)
                    }
                }

                Divider()

                // Video Effects
                VStack(alignment: .leading, spacing: 8) {
                    Text("Video Effects")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    // Blur
                    HStack {
                        Image(systemName: "aqi.medium")
                            .frame(width: 20)
                        Text("Blur")
                        Spacer()
                        Slider(value: $effectConfig.blurRadius, in: 0...30, step: 1)
                            .frame(width: 150)
                        Text("\(Int(effectConfig.blurRadius))")
                            .frame(width: 30, alignment: .trailing)
                            .font(.caption)
                    }

                    // Brightness
                    HStack {
                        Image(systemName: "sun.max")
                            .frame(width: 20)
                        Text("Brightness")
                        Spacer()
                        Slider(value: $effectConfig.brightness, in: -0.5...0.5, step: 0.05)
                            .frame(width: 150)
                        Text("\(Int(effectConfig.brightness * 100))%")
                            .frame(width: 40, alignment: .trailing)
                            .font(.caption)
                    }

                    // Saturation
                    HStack {
                        Image(systemName: "drop.halffull")
                            .frame(width: 20)
                        Text("Saturation")
                        Spacer()
                        Slider(value: $effectConfig.saturation, in: 0...2, step: 0.1)
                            .frame(width: 150)
                        Text(String(format: "%.1f", effectConfig.saturation))
                            .frame(width: 30, alignment: .trailing)
                            .font(.caption)
                    }

                    // Warmth
                    HStack {
                        Image(systemName: "thermometer.medium")
                            .frame(width: 20)
                        Text("Warmth")
                        Spacer()
                        Slider(value: $effectConfig.warmth, in: 2500...8000, step: 250)
                            .frame(width: 150)
                        Text("\(Int(effectConfig.warmth))K")
                            .frame(width: 50, alignment: .trailing)
                            .font(.caption)
                    }

                    // Vignette
                    HStack {
                        Image(systemName: "circle.dashed")
                            .frame(width: 20)
                        Text("Vignette")
                        Spacer()
                        Slider(value: $effectConfig.vignetteIntensity, in: 0...5, step: 0.5)
                            .frame(width: 150)
                        Text(String(format: "%.1f", effectConfig.vignetteIntensity))
                            .frame(width: 30, alignment: .trailing)
                            .font(.caption)
                    }

                    // Auto time-of-day tint
                    Toggle("Auto warm tint by time of day", isOn: $effectConfig.autoTimeTint)
                        .font(.caption)
                }
                .onChange(of: effectConfig) { _, _ in
                    applyEffects()
                }

                Divider()

                // Lock Screen
                Toggle(isOn: $setAsLockScreen) {
                    Label("Set as Lock Screen wallpaper", systemImage: "lock.display")
                }
                .onChange(of: setAsLockScreen) { _, newValue in
                    if newValue {
                        screenManager.extractLockScreenFrame(for: screen)
                    }
                }
            }
            .padding(14)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    // MARK: - Wallpaper Type Picker

    private var wallpaperTypePicker: some View {
        Picker("Wallpaper Type", selection: $selectedWallpaperType) {
            ForEach(WallpaperType.allCases) { type in
                Label(type.rawValue, systemImage: type.iconName).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .padding(.bottom, 4)
        .onChange(of: selectedWallpaperType) { _, newType in
            if newType == .video {
                screenManager.switchToVideoWallpaper(for: screen)
            }
        }
    }

    // MARK: - HTML Wallpaper Section

    private var htmlWallpaperSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Web / HTML Wallpaper", systemImage: "globe")
                    .font(.headline)

                Divider()

                HStack {
                    TextField("Enter URL (https://...) or local HTML path", text: $htmlContent)
                        .textFieldStyle(.roundedBorder)

                    Button("Load") {
                        guard !htmlContent.isEmpty else { return }
                        screenManager.setHTMLWallpaper(url: htmlContent, for: screen)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(htmlContent.isEmpty)
                }

                Text("Supports web URLs, local .html files, or inline HTML code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    // MARK: - Shader Wallpaper Section

    private var shaderWallpaperSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Shader Wallpaper", systemImage: "wand.and.stars")
                    .font(.headline)

                Divider()

                Text("GPU-rendered procedural animations")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ForEach(MetalShaderPreset.allCases) { preset in
                        Button {
                            selectedShaderPreset = preset
                            screenManager.setShaderWallpaper(preset: preset, for: screen)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: preset.iconName)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(selectedShaderPreset == preset ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                                    .clipShape(Circle())
                                Text(preset.rawValue)
                                    .font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    // MARK: - Effects Helpers

    private func updateParticleEffect(_ effect: ParticleEffect) {
        screenManager.updateParticleEffect(effect, for: screen)
    }

    private func applyEffects() {
        screenManager.updateEffectConfig(effectConfig, for: screen)
    }

    // MARK: - Helper Methods

    func setupPreviewPlayer() {
        // Only create a preview player if it doesn't already exist
        guard screen.previewPlayer == nil else {
            return
        }
        
        // First try to get existing configuration
        if let config = screenManager.getConfiguration(for: screen) {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: config.videoBookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                guard url.startAccessingSecurityScopedResource() else {
                    Logger.error("Failed to access security scoped resource for preview", category: .ui)
                    return
                }
                
                // Create a new preview player with more robust initialization
                let asset = AVURLAsset(url: url)
                let playerItem = AVPlayerItem(asset: asset)
                
                // Set up quality of service for better performance
                playerItem.preferredForwardBufferDuration = 5.0
                
                let previewPlayer = AVPlayer(playerItem: playerItem)
                previewPlayer.volume = 0
                previewPlayer.automaticallyWaitsToMinimizeStalling = true
                
                screen.previewPlayer = previewPlayer
                
                url.stopAccessingSecurityScopedResource()
            } catch {
                Logger.error("Failed to set up preview player: \(error.localizedDescription)", category: .ui)
            }
        }
        // If no configuration but we have a video player, try to recreate from the same URL
        else if let videoPlayer = screen.videoPlayer, let videoURL = videoPlayer.videoURL {
            if videoURL.startAccessingSecurityScopedResource() {
                let asset = AVURLAsset(url: videoURL)
                let playerItem = AVPlayerItem(asset: asset)
                let previewPlayer = AVPlayer(playerItem: playerItem)
                previewPlayer.volume = 0
                
                screen.previewPlayer = previewPlayer
                videoURL.stopAccessingSecurityScopedResource()
            }
        }
    }
    
    private func loadScreenConfiguration() {
        if let config = screenManager.getConfiguration(for: screen) {
            // Only update the state properties if they've changed
            if playbackSpeed != config.playbackSpeed {
                playbackSpeed = config.playbackSpeed
            }

            if selectedFitMode != config.fitMode {
                selectedFitMode = config.fitMode
            }

            // Load new feature fields
            selectedParticleEffect = config.particleEffect
            effectConfig = config.effectConfig
            setAsLockScreen = config.setAsLockScreen
            if let preset = config.shaderPreset {
                selectedShaderPreset = preset
            }
            selectedWallpaperType = config.wallpaperType
            htmlContent = config.htmlContent ?? ""

            // Create preview player if none exists
            setupPreviewPlayer()
        }
    }
    
    private func cleanupPreviewPlayer() {
        // Only clean up the preview player if it exists
        if let previewPlayer = screen.previewPlayer {
            previewPlayer.pause()
            screen.previewPlayer = nil
        }
    }
    
    private func showFilePicker() {
        Logger.debug("Opening video file picker", category: .ui)
        let panel = ResourceUtilities.configureVideoOpenPanel()
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Logger.info("Video file selected: \(url.lastPathComponent)", category: .ui)
                // Save directory for next time
                SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
                handleSelectedFile(url: url)
            } else {
                Logger.debug("File picker canceled or no file selected", category: .ui)
            }
        }
    }
    
    private func handleSelectedFile(url: URL) {
        Logger.functionStart(category: .ui)
        
        withAnimation {
            isLoading = true
        }
        
        // Clean up any existing preview player
        cleanupPreviewPlayer()
        
        // First, create a preview player immediately to show feedback
        if url.startAccessingSecurityScopedResource() {
            Logger.debug("Security-scoped resource access granted for: \(url.lastPathComponent)", category: .fileAccess)
            
            // Create a preview player immediately
            let asset = AVURLAsset(url: url)
            let playerItem = AVPlayerItem(asset: asset)
            let previewPlayer = AVPlayer(playerItem: playerItem)
            previewPlayer.volume = 0
            
            // Update the UI with the new preview player
            DispatchQueue.main.async {
                // Set the new preview player
                self.screen.previewPlayer = previewPlayer
                // Start preview playback
                previewPlayer.play()
                Logger.debug("Preview player created and started", category: .ui)
            }
            
            // Now create the security-scoped bookmark for permanent access
            if let bookmarkData = ResourceUtilities.createBookmark(for: url) {
                // If everything is okay, set the video for the wallpaper
                screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
                Logger.info("Video bookmark created and set for screen \(screen.id)", category: .fileAccess)
            } else {
                errorMessage = "Error creating secure bookmark. Please try selecting a different video file."
                showErrorAlert = true
                Logger.error("Failed to create bookmark for: \(url.lastPathComponent)", category: .fileAccess)
            }
            
            url.stopAccessingSecurityScopedResource()
        } else {
            errorMessage = "Failed to access the selected file. Please try selecting it again."
            showErrorAlert = true
            Logger.error("Security-scoped resource access denied for: \(url.lastPathComponent)", category: .fileAccess)
        }
        
        // Remove loading state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation {
                self.isLoading = false
            }
            Logger.functionEnd(category: .ui)
        }
    }
    
    private func clearVideo() {
        // Show confirmation dialog
        let alert = NSAlert()
        alert.messageText = "Clear Wallpaper Video"
        alert.informativeText = "Are you sure you want to remove this video? This will delete all configuration for this screen."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Video")
        alert.addButton(withTitle: "Cancel")
        
        // Use the first button as the destructive action
        alert.buttons.first?.hasDestructiveAction = true
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // User confirmed
            cleanupPreviewPlayer()
            screenManager.clearVideoForScreen(screen)
            
            // Reset local state
            withAnimation {
                isPlayerPlaying = false
            }
        }
    }
    
    private func togglePlayback() {
        if let player = screen.videoPlayer {
            if player.isPlaying {
                player.pause()
                isPlayerPlaying = false
            } else {
                player.play()
                isPlayerPlaying = true
            }
        }
    }
    
    private func getScreenRefreshRate() -> Int {
        screenManager.getScreenRefreshRate(for: screen.id)
    }
}

// MARK: - Video Information View
struct VideoInformationView: View {
    let player: AVPlayer
    let screenRefreshRate: Int
    
    @State private var videoDuration: Double = 0
    @State private var videoResolution: (width: Int, height: Int)? = nil
    @State private var videoName: String = ""
    @State private var videoFrameRate: Double = 0
    @State private var fileSize: String = ""
    @State private var isInfoExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with expand/collapse button
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "film.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(videoName.isEmpty ? "Unnamed Video" : videoName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isInfoExpanded.toggle()
                    }
                }) {
                    Image(systemName: isInfoExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // Expandable details section
            if isInfoExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    
                    // Video specifications in a grid layout
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 20),
                        GridItem(.flexible(), spacing: 20)
                    ], spacing: 12) {
                        // Duration
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Duration")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(FormatUtils.formatDuration(videoDuration))
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                        
                        // Resolution
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resolution")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.3.group")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let resolution = videoResolution {
                                    Text("\(resolution.width)×\(resolution.height)")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                } else {
                                    Text("Unknown")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        
                        // Frame rate
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Frame Rate")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "speedometer")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if videoFrameRate > 0 {
                                    Text("\(Int(videoFrameRate)) FPS")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                } else {
                                    Text("Unknown")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        
                        // Aspect ratio
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aspect Ratio")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "aspectratio")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let resolution = videoResolution,
                                   resolution.width > 0, resolution.height > 0 {
                                    Text(calculateAspectRatio(width: resolution.width, height: resolution.height))
                                        .font(.caption)
                                        .fontWeight(.medium)
                                } else {
                                    Text("Unknown")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        
                        // Screen refresh rate
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screen Rate")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "display")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(screenRefreshRate) Hz")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                        
                        // File size
                        VStack(alignment: .leading, spacing: 2) {
                            Text("File Size")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "doc")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(fileSize.isEmpty ? "Unknown" : fileSize)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
        .onAppear {
            loadVideoInformation()
        }
    }
    
    private func loadVideoInformation() {
        guard let playerItem = player.currentItem else { return }
        
        // Get video duration safely
        let duration = playerItem.duration
        videoDuration = duration.isValid ? CMTimeGetSeconds(duration) : 0
        
        // Get video name and file size from URL
        if let urlAsset = playerItem.asset as? AVURLAsset {
            videoName = urlAsset.url.lastPathComponent
            
            // Get file size
            let path = urlAsset.url.path
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                if let size = attributes[.size] as? NSNumber {
                    fileSize = FormatUtils.formatBytes(size.int64Value)
                }
            } catch {
                print("Error getting file size: \(error)")
            }
        }
        
        // Load video details asynchronously
        Task {
            do {
                // Asynchronously load video tracks
                let videoTracks = try await playerItem.asset.loadTracks(withMediaType: .video)
                guard let track = videoTracks.first else { return }
                
                // Asynchronously load the needed properties
                let naturalSize = try await track.load(.naturalSize)
                let preferredTransform = try await track.load(.preferredTransform)
                let nominalFrameRate = try await track.load(.nominalFrameRate)
                
                // Apply the transform to the natural size to get the actual video dimensions
                let transformedSize = naturalSize.applying(preferredTransform)
                videoResolution = (width: abs(Int(transformedSize.width)),
                                   height: abs(Int(transformedSize.height)))
                videoFrameRate = Double(nominalFrameRate)
            } catch {
                print("Error loading video details: \(error)")
            }
        }
    }
    
    private func calculateAspectRatio(width: Int, height: Int) -> String {
        if width == 0 || height == 0 { return "Unknown" }
        
        // Common aspect ratios
        let ratio = Double(width) / Double(height)
        
        // Check for common aspect ratios with some tolerance
        let tolerance = 0.05
        if abs(ratio - 16.0/9.0) < tolerance {
            return "16:9"
        } else if abs(ratio - 4.0/3.0) < tolerance {
            return "4:3"
        } else if abs(ratio - 21.0/9.0) < tolerance {
            return "21:9"
        } else if abs(ratio - 1.0) < tolerance {
            return "1:1"
        } else {
            // Return simplified aspect ratio or the decimal value
            return String(format: "%.2f:1", ratio)
        }
    }
}

// MARK: - Custom Styles

struct ContainerGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(4)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

