import SwiftUI
import AVKit

struct ScreenDetailView: View {
    @ObservedObject var screen: Screen
    @EnvironmentObject private var screenManager: ScreenManager
    
    @State private var playbackSpeed: Double = 1.0
    @State private var selectedFitMode: VideoFitMode = .aspectFill
    @State private var pauseOnBattery: Bool = false
    @State private var isLoading: Bool = false
    
    // New state variables for tracking playback
    @State private var isPlayerPlaying: Bool = false
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    // Track whether this view is appearing/disappearing to prevent unnecessary updates
    @State private var isViewActive = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                displayHeader
                
                if isLoading {
                    loadingView
                } else if screen.videoPlayer != nil || screen.previewPlayer != nil {
                    videoPreviewSection
                    playbackControlsSection
                    videoOptionsSection
                    powerManagementSection
                } else {
                    emptyStateView
                }
                
                Spacer(minLength: 20)
            }
            .padding(24)
            .onAppear {
                isViewActive = true
                loadScreenConfiguration()
                // Initialize playback state on appearance
                isPlayerPlaying = screen.videoPlayer?.isPlaying ?? false
                setupPlaybackStateObserver()
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
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: "display")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(screen.name)
                        .font(.system(size: 24, weight: .semibold))
                    
                    HStack(spacing: 8) {
                        Text("Resolution: \(Int(screen.frame.width))×\(Int(screen.frame.height))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Text("Refresh Rate: \(getScreenRefreshRate()) Hz")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            Button(action: {
                screenManager.reloadVideoForScreen(screen)
            }) {
                Label("Reload", systemImage: "arrow.clockwise")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reload video for this display")
        }
        .padding(.bottom, 8)
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()
            
            Text("Loading video...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(Color(NSColor.textBackgroundColor).opacity(0.4))
        .cornerRadius(12)
    }
    
    private var emptyStateView: some View {
        FileSelectView(action: showFilePicker)
            .frame(height: 300)
    }
    
    private var videoPreviewSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Video Preview", systemImage: "film")
                    .font(.headline)
                
                if let player = screen.previewPlayer {
                    VStack(spacing: 8) {
                        // Video player with consistent width
                        //                        VideoPlayer(player: player)
                        //                            .frame(maxWidth: .infinity)
                        //                            .frame(height: 300)
                        //                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        //                            .overlay(
                        //                                RoundedRectangle(cornerRadius: 6)
                        //                                    .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                        //                            )
                        //                            .shadow(radius: 3, y: 2)
                        CustomVideoPlayer(player: player, fitMode: selectedFitMode)
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                            .shadow(radius: 3, y: 2)
                        
                        // Video information
                        VideoInformationView(player: player, screenRefreshRate: getScreenRefreshRate())
                    }
                } else {
                    // Fixed width file select view that matches video player width
                    GeometryReader { geo in
                        FileSelectView(action: showFilePicker)
                            .frame(width: geo.size.width)
                    }
                    .frame(height: 300)
                }
            }
            .padding(16)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
    
    private var playbackControlsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Playback Controls", systemImage: "slider.horizontal.3")
                    .font(.headline)
                
                VStack(spacing: 20) {
                    // Top Controls Row
                    HStack(spacing: 16) {
                        Button(action: showFilePicker) {
                            Label("Change Video", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        
                        Button(action: clearVideo) {
                            Label("Clear Video", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .foregroundColor(.red)
                        .help("Remove this video and its configuration")
                        
                        Spacer()
                        
                        PlaybackButton(
                            isPlaying: isPlayerPlaying,
                            action: togglePlayback
                        )
                    }
                    
                    Divider()
                    
                    // Playback Speed Control
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Playback Speed:")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            
                            Text(String(format: "%.1fx", playbackSpeed))
                                .font(.subheadline)
                                .bold()
                                .foregroundColor(.secondary)
                        }
                        
                        HStack(spacing: 12) {
                            Image(systemName: "tortoise")
                                .foregroundColor(.secondary)
                            
                            Slider(value: $playbackSpeed, in: 0.5...2.0, step: 0.1)
                                .onChange(of: playbackSpeed) { oldValue, newValue in
                                    if oldValue != newValue {
                                        screen.videoPlayer?.setPlaybackSpeed(newValue)
                                        screenManager.updatePlaybackSpeed(newValue, for: screen)
                                    }
                                }
                            
                            Image(systemName: "hare")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(16)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
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
            isPlayerPlaying = false
        }
    }
    
    private var videoOptionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Video Options", systemImage: "rectangle.3.group")
                    .font(.headline)
                
                // Fit Mode Selector with visual indicators
                VStack(alignment: .leading, spacing: 12) {
                    Text("How should the video fit your screen?")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    
                    FitModePicker(
                        selection: $selectedFitMode,
                        onChange: { newMode in
                            screenManager.updateFitMode(newMode, for: screen)
                        }
                    )
                }
                
                Divider()
                
                // Frame Rate Options - only show if we have a video player
                if let player = screen.videoPlayer, player.videoFrameRate > 0 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Frame Rate Management")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        
                        Button(action: {
                            optimizeVideoFrameRate()
                        }) {
                            Label("Optimize Frame Rate", systemImage: "speedometer")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .help("Limit video frame rate to match your display refresh rate to reduce GPU usage")
                        
                        Text("Original video: \(Int(player.videoFrameRate)) FPS, Screen: \(getScreenRefreshRate()) Hz")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
    
    private var powerManagementSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Power Management", systemImage: "bolt.circle")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Pause this video when on battery power", isOn: $pauseOnBattery)
                        .onChange(of: pauseOnBattery) { oldValue, newValue in
                            if oldValue != newValue {
                                screenManager.updatePowerSettings(pauseOnBattery: newValue, for: screen)
                            }
                        }
                    
                    Text("This helps conserve battery life when your Mac is unplugged")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
    
    // MARK: - Helper Methods
    
    private func setupPlaybackStateObserver() {
        // Add periodic observation of playing state
        if let videoPlayer = screen.videoPlayer {
            // Create a timer to check the playback state
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                if !isViewActive {
                    timer.invalidate()
                    return
                }
                
                let currentPlaying = videoPlayer.isPlaying
                if isPlayerPlaying != currentPlaying {
                    isPlayerPlaying = currentPlaying
                }
            }
        }
    }
    
    private func loadScreenConfiguration() {
        if let config = screenManager.getConfiguration(for: screen) {
            // Only update the state properties if they've changed
            // This prevents unnecessary UI updates
            if playbackSpeed != config.playbackSpeed {
                playbackSpeed = config.playbackSpeed
            }
            
            if selectedFitMode != config.fitMode {
                selectedFitMode = config.fitMode
            }
            
            if pauseOnBattery != config.pauseOnBattery {
                pauseOnBattery = config.pauseOnBattery
            }
            
            // Create preview player if none exists
            setupPreviewPlayer()
        }
    }
    
    private func setupPreviewPlayer() {
        // Only create a preview player if it doesn't already exist
        guard screen.previewPlayer == nil,
              let config = screenManager.getConfiguration(for: screen) else {
            return
        }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: config.videoBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            guard url.startAccessingSecurityScopedResource() else {
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
            print("Failed to set up preview player: \(error.localizedDescription)")
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
        let panel = ResourceUtilities.configureVideoOpenPanel()
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                // Save directory for next time
                SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
                handleSelectedFile(url: url)
            }
        }
    }
    
    private func handleSelectedFile(url: URL) {
        // Display loading state first
        isLoading = true
        
        // Clean up any existing preview player
        cleanupPreviewPlayer()
        
        // First, create a preview player immediately to show feedback
        if url.startAccessingSecurityScopedResource() {
            // Create a preview player immediately
            let asset = AVURLAsset(url: url)
            let playerItem = AVPlayerItem(asset: asset)
            let previewPlayer = AVPlayer(playerItem: playerItem)
            previewPlayer.volume = 0
            
            // Update the UI with the new preview player
            DispatchQueue.main.async {
                // Set the new preview player
                screen.previewPlayer = previewPlayer
                // Start preview playback
                previewPlayer.play()
            }
            
            // Now create the security-scoped bookmark for permanent access
            if let bookmarkData = ResourceUtilities.createBookmark(for: url) {
                // If everything is okay, set the video for the wallpaper
                screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
            } else {
                errorMessage = "Error creating secure bookmark. Please try selecting a different video file."
                showErrorAlert = true
            }
            
            url.stopAccessingSecurityScopedResource()
        } else {
            errorMessage = "Failed to access the selected file. Please try selecting it again."
            showErrorAlert = true
        }
        
        // Remove loading state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isLoading = false
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
    
    // Optimize video frame rate to match display refresh rate
    private func optimizeVideoFrameRate() {
        guard let player = screen.videoPlayer, player.videoFrameRate > 0 else { return }
        
        let screenRate = Float(getScreenRefreshRate())
        let videoRate = Float(player.videoFrameRate)
        
        // Only limit if video rate is higher than screen rate
        if videoRate > screenRate && screenRate > 0 {
            player.setFrameRateLimit(screenRate)
        } else {
            // Use original frame rate
            player.setFrameRateLimit(videoRate)
        }
    }
}

struct FileSelectView: View {
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
                
                Text("Select Video")
                    .font(.headline)
                
                Text("Choose a video file to display as your wallpaper")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300) // Match the VideoPlayer height for consistency
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundColor(.accentColor.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }
}

struct PlaybackButton: View {
    let isPlaying: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20))
                Text(isPlaying ? "Pause" : "Play")
            }
            .frame(minWidth: 100)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
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
                        selection = mode
                        onChange(mode)
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title Section
            HStack {
                Image(systemName: "film.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(videoName.isEmpty ? "Unnamed Video" : videoName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            
            // Duration and Aspect Ratio Section
            HStack {
                Image(systemName: "timer")
                    .foregroundColor(.secondary)
                Text(formatDuration(videoDuration))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if let resolution = videoResolution,
                   resolution.width > 0, resolution.height > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "aspectratio")
                            .foregroundColor(.secondary)
                        Text(calculateAspectRatio(width: resolution.width, height: resolution.height))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Divider()
            
            // Resolution and Frame Rate Section
            HStack {
                if let resolution = videoResolution {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.and.pencil.and.ellipsis")
                            .foregroundColor(.secondary)
                        Text("\(resolution.width) × \(resolution.height)")
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if videoFrameRate > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .foregroundColor(.secondary)
                        Text("\(Int(videoFrameRate)) FPS")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .font(.caption)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
        .onAppear {
            loadVideoInformation()
        }
        
    }
    
    private func loadVideoInformation() {
        guard let playerItem = player.currentItem else { return }
        
        // Get video duration safely
        let duration = playerItem.duration
        videoDuration = duration.isValid ? CMTimeGetSeconds(duration) : 0
        
        // Get video name from URL
        if let urlAsset = playerItem.asset as? AVURLAsset {
            videoName = urlAsset.url.lastPathComponent
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

// Custom group box style for consistent appearance
struct ContainerGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(4)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}
