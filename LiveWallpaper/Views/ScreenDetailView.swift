import SwiftUI
import AVKit

struct ScreenDetailView: View {
    @ObservedObject var screen: Screen
    @EnvironmentObject private var screenManager: ScreenManager
    
    @State private var playbackSpeed: Double = 1.0
    @State private var selectedFitMode: VideoFitMode = .aspectFill
    @State private var isLoading: Bool = false
    @State private var isPlayerPlaying: Bool = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var isViewActive = false
    @State private var currentVideoPosition: Double = 0
    @State private var videoDuration: Double = 1.0
    
    // Layout variables
    @State private var useCompactLayout = false
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                displayHeader
                
                if isLoading {
                    loadingView
                } else if screen.videoPlayer != nil || screen.previewPlayer != nil {
                    // Use different layouts based on screen size
                    if useCompactLayout {
                        // Compact layout for smaller screens
                        VStack(spacing: 20) {
                            videoPreviewSection
                            playbackControlsSection
                            videoOptionsSection
                        }
                    } else {
                        // Two-column layout for larger screens
                        VStack(spacing: 20) {
                            videoPreviewSection
                            
                            // Side-by-side controls and options
                            HStack(alignment: .top, spacing: 20) {
                                playbackControlsSection
                                videoOptionsSection
                            }
                        }
                    }
                } else {
                    enhancedEmptyStateView
                }
            }
            .padding(24)
            .animation(.easeInOut(duration: 0.2), value: useCompactLayout)
            .animation(.easeInOut(duration: 0.2), value: isLoading)
            .onAppear {
                isViewActive = true
                loadScreenConfiguration()
                isPlayerPlaying = screen.videoPlayer?.isPlaying ?? false
                setupPlaybackStateObserver()
                setupVideoProgressObserver()
                
                // Check screen size to determine layout
                if let screenWidth = NSScreen.main?.frame.width {
                    useCompactLayout = screenWidth < 1200
                }
                
                // Set up observer for video reload notifications
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main
                ) { _ in
                    if screen.previewPlayer == nil {
                        setupPreviewPlayer()
                    }
                }
            }
            .onDisappear {
                isViewActive = false
                cleanupPreviewPlayer()
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
    
    // MARK: - UI Components
    
    private var displayHeader: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "display")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .foregroundColor(.accentColor)
                    .background(
                        Circle()
                            .fill(Color.accentColor.opacity(0.1))
                            .frame(width: 60, height: 60)
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(screen.name)
                        .font(.system(size: 24, weight: .semibold))
                    
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack(spacing: 4) {
                            Image(systemName: "gauge.medium")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(getScreenRefreshRate()) Hz")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        if let player = screen.videoPlayer, player.isPlaying {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                Text("Playing")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                Spacer()
                
                HStack(spacing: 10) {
                    Button(action: {
                        screenManager.reloadVideoForScreen(screen)
                    }) {
                        Label("Reload", systemImage: "arrow.clockwise")
                            .frame(minWidth: 80)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Reload video for this display")
                }
            }
            
            Divider()
                .padding(.vertical, 4)
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.bottom, 8)
            
            Text("Loading video...")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("This may take a moment depending on the file size")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(Color(colorScheme == .dark ? NSColor.darkGray : NSColor.lightGray).opacity(0.15))
        .cornerRadius(16)
        .transition(.opacity)
    }
    
    private var enhancedEmptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "film")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
                .padding(.bottom, 10)
            
            Text("No Video Selected")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("Choose a video file to display as your desktop wallpaper")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            
            Button(action: showFilePicker) {
                Label("Select Video File", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .shadow(color: Color.accentColor.opacity(0.3), radius: 5, x: 0, y: 2)
            .padding(.top, 10)
            
            Text("Supported formats: MP4, MOV, M4V")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: 400)
        .background(Color(colorScheme == .dark ? NSColor.darkGray : NSColor.lightGray).opacity(0.1))
        .cornerRadius(16)
        .transition(.opacity)
    }
    
    private var videoPreviewSection: some View {
        VStack(spacing: 0) {
            if let player = screen.previewPlayer {
                // Video player with progress slider
                ZStack(alignment: .bottom) {
                    // Video display
                    CustomVideoPlayer(player: player, fitMode: selectedFitMode)
                        .aspectRatio(16/9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 300, maxHeight: 400)
                        .cornerRadius(12)
                        .clipped()
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
                    
                    // Playback controls overlay
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
                            Text(formatTime(currentVideoPosition))
                                .font(.caption2)
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            Text(formatTime(videoDuration))
                                .font(.caption2)
                                .foregroundColor(.white)
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
                    .cornerRadius(12, corners: [.bottomLeft, .bottomRight])
                }
                
                // Video information
                VideoInformationView(player: player, screenRefreshRate: getScreenRefreshRate())
                    .padding(.top, 12)
            } else if screen.videoPlayer != nil {
                // Display a message when preview is unavailable
                VStack(spacing: 16) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    
                    Text("Video is playing as wallpaper")
                        .font(.headline)
                    
                    Text("Preview unavailable")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Button("Reload Preview") {
                        setupPreviewPlayer()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 300)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .onAppear {
                    setupPreviewPlayer()
                }
            } else {
                // No player configured
                FileSelectView(action: showFilePicker)
                    .frame(minHeight: 300)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
    
    private var playbackControlsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 20) {
                // Section header
                Label("Playback Controls", systemImage: "slider.horizontal.3")
                    .font(.headline)
                
                // Play/Pause button
                HStack {
                    Spacer()
                    PlaybackButton(
                        isPlaying: isPlayerPlaying,
                        action: togglePlayback
                    )
                    .scaleEffect(1.2)
                    .padding(.vertical, 6)
                    Spacer()
                }
                
                Divider()
                
                // Playback speed control
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Playback Speed")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Spacer()
                        
                        Text(String(format: "%.1fx", playbackSpeed))
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(8)
                    }
                    
                    HStack(spacing: 12) {
                        Text("0.5x")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Slider(value: $playbackSpeed, in: 0.5...2.0, step: 0.1)
                            .onChange(of: playbackSpeed) { oldValue, newValue in
                                if oldValue != newValue {
                                    screen.videoPlayer?.setPlaybackSpeed(newValue)
                                    screenManager.updatePlaybackSpeed(newValue, for: screen)
                                }
                            }
                        
                        Text("2.0x")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Speed presets
                    HStack(spacing: 8) {
                        ForEach([0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { speed in
                            Button(action: {
                                playbackSpeed = speed
                                screen.videoPlayer?.setPlaybackSpeed(speed)
                                screenManager.updatePlaybackSpeed(speed, for: screen)
                            }) {
                                Text(speed == 1.0 ? "Normal" : "\(String(format: "%.1f", speed))x")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .background(playbackSpeed == speed ? Color.accentColor.opacity(0.2) : Color.clear)
                            .cornerRadius(4)
                        }
                    }
                    .padding(.top, 4)
                }
                
                Divider()
                
                // File actions
                HStack(spacing: 16) {
                    Button(action: showFilePicker) {
                        Label("Change Video", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    Button(action: clearVideo) {
                        Label("Clear", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .foregroundColor(.red)
                    .help("Remove this video and its configuration")
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .frame(minWidth: useCompactLayout ? nil : 300)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }
    
    private var videoOptionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 20) {
                // Section header
                Label("Video Options", systemImage: "rectangle.3.group")
                    .font(.headline)
                
                // Video fit mode
                VStack(alignment: .leading, spacing: 12) {
                    Text("Video Fit Mode")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    // Visual fit mode selector
                    VStack(spacing: 16) {
                        // Preview thumbnails for each fit mode
                        HStack(spacing: 20) {
                            ForEach(VideoFitMode.allCases) { mode in
                                VStack(spacing: 8) {
                                    // Visual preview
                                    ZStack {
                                        // Background
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(selectedFitMode == mode ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                                            .frame(width: 100, height: 70)
                                        
                                        // Screen outline
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.gray, lineWidth: 1)
                                            .frame(width: 90, height: 60)
                                        
                                        // "Video" content
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(Color.accentColor.opacity(0.7))
                                                .frame(
                                                    width: mode == .stretch ? 80 : (mode == .aspectFill ? 90 : 60),
                                                    height: mode == .stretch ? 50 : (mode == .aspectFill ? 50 : 40)
                                                )
                                            
                                            Image(systemName: "play.fill")
                                                .foregroundColor(.white)
                                                .font(.system(size: 12))
                                        }
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedFitMode == mode ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                                    .onTapGesture {
                                        withAnimation {
                                            selectedFitMode = mode
                                            screenManager.updateFitMode(mode, for: screen)
                                        }
                                    }
                                    
                                    Text(mode.rawValue)
                                        .font(.caption)
                                        .foregroundColor(selectedFitMode == mode ? .primary : .secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        
                        // Description of selected mode
                        Text(selectedFitMode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                
                Divider()
                
                // Add Frame Rate Control section if applicable
                if let player = screen.videoPlayer, player.videoFrameRate > 0 {
                    FrameRateControlView(screen: screen)
                } else {
                    // Show placeholder for when frame rate info is not available
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Frame Rate Control", systemImage: "gauge.high")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("Frame rate information is unavailable or video is not loaded")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(16)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .frame(minWidth: useCompactLayout ? nil : 300)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
    
    // MARK: - Helper Methods
    
    private func setupPlaybackStateObserver() {
        // Create a timer to check the playback state
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            if !isViewActive {
                timer.invalidate()
                return
            }
            
            if let videoPlayer = screen.videoPlayer {
                let currentPlaying = videoPlayer.isPlaying
                if isPlayerPlaying != currentPlaying {
                    withAnimation {
                        isPlayerPlaying = currentPlaying
                    }
                }
            }
        }
    }
    
    private func setupVideoProgressObserver() {
        // Update the time position for the slider
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            if !isViewActive {
                timer.invalidate()
                return
            }
            
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
    
    // Get screen refresh rate for the current display
    private func getScreenRefreshRate() -> Int {
        // Use CGDisplayMode to get accurate refresh rate
        guard let displayID = screen.id as CGDirectDisplayID?,
              let mode = CGDisplayCopyDisplayMode(displayID) else {
            return 60 // Default to 60Hz if we can't determine
        }
        
        let refreshRate = mode.refreshRate
        return refreshRate > 0 ? Int(refreshRate) : 60
    }
    
    // Format time for video playback display
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, !seconds.isNaN else { return "0:00" }
        
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

// MARK: - Helper Views
struct FileSelectView: View {
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 20) {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                
                Text("Select Video")
                    .font(.headline)
                
                Text("Choose a video file to display as your wallpaper")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .frame(maxWidth: 250)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [6]),
                        antialiased: true
                    )
                    .foregroundColor(.accentColor.opacity(0.6))
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

struct PlaybackButton: View {
    let isPlaying: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // Play/pause icon in circle
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 60, height: 60)
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 4, x: 0, y: 2)
                    
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .offset(x: isPlaying ? 0 : 2) // Slight offset for play icon to appear centered
                }
                
                // Label text
                Text(isPlaying ? "Pause" : "Play")
                    .font(.callout)
                    .fontWeight(.medium)
            }
            .frame(minWidth: 100)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }
}

struct FitModePicker: View {
    @Binding var selection: VideoFitMode
    let onChange: (VideoFitMode) -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            ForEach(VideoFitMode.allCases) { mode in
                FitModeOption(
                    mode: mode,
                    isSelected: selection == mode,
                    action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = mode
                            onChange(mode)
                        }
                    }
                )
            }
        }
    }
}

struct FitModeOption: View {
    let mode: VideoFitMode
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                    .frame(width: 80, height: 60)
                
                Image(systemName: mode.iconName)
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? .accentColor : .gray)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            
            Text(mode.rawValue)
                .font(.caption)
                .foregroundColor(isSelected ? .primary : .secondary)
            
            Text(mode.description)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 100)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .onTapGesture {
            action()
        }
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
                        .foregroundColor(.accentColor)
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
                        .foregroundColor(.secondary)
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
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(formatDuration(videoDuration))
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                        
                        // Resolution
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resolution")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.3.group")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if let resolution = videoResolution {
                                    Text("\(resolution.width)×\(resolution.height)")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                } else {
                                    Text("Unknown")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        // Frame rate
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Frame Rate")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "speedometer")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if videoFrameRate > 0 {
                                    Text("\(Int(videoFrameRate)) FPS")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                } else {
                                    Text("Unknown")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        // Aspect ratio
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aspect Ratio")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "aspectratio")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if let resolution = videoResolution,
                                   resolution.width > 0, resolution.height > 0 {
                                    Text(calculateAspectRatio(width: resolution.width, height: resolution.height))
                                        .font(.caption)
                                        .fontWeight(.medium)
                                } else {
                                    Text("Unknown")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        // Screen refresh rate
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screen Rate")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "display")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(screenRefreshRate) Hz")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                        
                        // File size
                        VStack(alignment: .leading, spacing: 2) {
                            Text("File Size")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "doc")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
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
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
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
                    fileSize = formatFileSize(size.int64Value)
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
    
    private func formatDuration(_ seconds: Double) -> String {
        // Handle invalid values
        guard seconds.isFinite, !seconds.isNaN else {
            return "Unknown"
        }
        
        // Safely convert to integer
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.0f KB", kb)
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

// MARK: - Custom Styles and Extensions
struct ContainerGroupBoxStyle: GroupBoxStyle {
    @Environment(\.colorScheme) private var colorScheme
    
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(4)
        .background(colorScheme == .dark ? Color(NSColor.controlBackgroundColor) : Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

// Extension to apply rounded corners to specific corners only
extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

// Custom shape for rounded corners
struct RoundedCornerShape: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let topLeft = corners.contains(.topLeft)
        let topRight = corners.contains(.topRight)
        let bottomLeft = corners.contains(.bottomLeft)
        let bottomRight = corners.contains(.bottomRight)
        
        let width = rect.width
        let height = rect.height
        
        // Top left corner
        if topLeft {
            path.move(to: CGPoint(x: 0, y: radius))
            path.addCurve(
                to: CGPoint(x: radius, y: 0),
                control1: CGPoint(x: 0, y: radius / 2),
                control2: CGPoint(x: radius / 2, y: 0)
            )
        } else {
            path.move(to: CGPoint(x: 0, y: 0))
        }
        
        // Top edge and top right corner
        if topRight {
            path.addLine(to: CGPoint(x: width - radius, y: 0))
            path.addCurve(
                to: CGPoint(x: width, y: radius),
                control1: CGPoint(x: width - radius / 2, y: 0),
                control2: CGPoint(x: width, y: radius / 2)
            )
        } else {
            path.addLine(to: CGPoint(x: width, y: 0))
        }
        
        // Right edge and bottom right corner
        if bottomRight {
            path.addLine(to: CGPoint(x: width, y: height - radius))
            path.addCurve(
                to: CGPoint(x: width - radius, y: height),
                control1: CGPoint(x: width, y: height - radius / 2),
                control2: CGPoint(x: width - radius / 2, y: height)
            )
        } else {
            path.addLine(to: CGPoint(x: width, y: height))
        }
        
        // Bottom edge and bottom left corner
        if bottomLeft {
            path.addLine(to: CGPoint(x: radius, y: height))
            path.addCurve(
                to: CGPoint(x: 0, y: height - radius),
                control1: CGPoint(x: radius / 2, y: height),
                control2: CGPoint(x: 0, y: height - radius / 2)
            )
        } else {
            path.addLine(to: CGPoint(x: 0, y: height))
        }
        
        // Close the path
        path.closeSubpath()
        
        return path
    }
}

// Custom struct for UIRectCorner in macOS
struct RectCorner: OptionSet {
    let rawValue: Int
    
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomRight = RectCorner(rawValue: 1 << 2)
    static let bottomLeft = RectCorner(rawValue: 1 << 3)
    
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}
