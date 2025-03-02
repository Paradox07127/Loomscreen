import SwiftUI
import AVKit

struct ScreenDetailView: View {
    @ObservedObject var screen: Screen
    @EnvironmentObject private var screenManager: ScreenManager
    
    @State private var playbackSpeed: Double = 1.0
    @State private var selectedFitMode: VideoFitMode = .aspectFill
    @State private var pauseOnBattery: Bool = false
    @State private var isLoading: Bool = false
    
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
                    Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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
                        VideoPlayer(player: player)
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                            .shadow(radius: 3, y: 2)
                        
                        // Video information
                        VideoInformationView(player: player)
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
                        
                        Spacer()
                        
                        PlaybackButton(
                            isPlaying: screen.videoPlayer?.isPlaying ?? false,
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
            
            // Create a new preview player
            let asset = AVURLAsset(url: url)
            let playerItem = AVPlayerItem(asset: asset)
            let previewPlayer = AVPlayer(playerItem: playerItem)
            previewPlayer.volume = 0
            
            // Set the preview player and start playback
            screen.previewPlayer = previewPlayer
            previewPlayer.play()
            
            // Stop accessing the resource when done with setup
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
        if screen.videoPlayer?.isPlaying ?? false {
            screen.videoPlayer?.pause()
        } else {
            screen.videoPlayer?.play()
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
    @State private var videoDuration: Double = 0
    @State private var videoResolution: (width: Int, height: Int)? = nil
    @State private var videoName: String = ""
    
    var body: some View {
        HStack(spacing: 16) {
            // Video file info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "film.fill")
                        .foregroundColor(.secondary)
                    Text(videoName.isEmpty ? "Unnamed Video" : videoName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                        .foregroundColor(.secondary)
                    Text(formatDuration(videoDuration))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Resolution info
            if let resolution = videoResolution {
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.and.pencil.and.ellipsis")
                            .foregroundColor(.secondary)
                        Text("\(resolution.width) × \(resolution.height)")
                            .foregroundColor(.secondary)
                    }
                    
                    // Video aspect ratio
                    if resolution.width > 0 && resolution.height > 0 {
                        HStack(spacing: 8) {
                            Image(systemName: "aspectratio")
                                .foregroundColor(.secondary)
                            Text(calculateAspectRatio(width: resolution.width, height: resolution.height))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .font(.caption)
        .padding(10)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
        .onAppear {
            loadVideoInformation()
        }
    }
    
    private func loadVideoInformation() {
        guard let playerItem = player.currentItem else { return }
        
        // Get video duration
        let duration = playerItem.duration
        videoDuration = duration.isValid ? CMTimeGetSeconds(duration) : 0
        
        // Get video name from URL
        if let urlAsset = playerItem.asset as? AVURLAsset {
            videoName = urlAsset.url.lastPathComponent
        }
        
        // Get video resolution using modern API
        if #available(macOS 13.0, *) {
            // Use modern async API
            Task {
                do {
                    // Load tracks
                    let tracks = try await playerItem.asset.loadTracks(withMediaType: .video)
                    
                    if let track = tracks.first {
                        // Load natural size and preferred transform
                        let naturalSize = try await track.load(.naturalSize)
                        let preferredTransform = try await track.load(.preferredTransform)
                        
                        // Apply transform to size
                        let size = naturalSize.applying(preferredTransform)
                        
                        // Update on main thread
                        await MainActor.run {
                            videoResolution = (width: abs(Int(size.width)), height: abs(Int(size.height)))
                        }
                    }
                } catch {
                    print("Error loading video track information: \(error.localizedDescription)")
                }
            }
        } else {
            // Fallback for older macOS versions
            if let track = playerItem.asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                videoResolution = (width: abs(Int(size.width)), height: abs(Int(size.height)))
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
