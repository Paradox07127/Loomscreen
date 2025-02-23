import SwiftUI
import UniformTypeIdentifiers
import AVKit

struct ContentView: View {
    @EnvironmentObject private var screenManager: ScreenManager
    @State private var selectedScreen: Screen?
    
    var body: some View {
        NavigationSplitView {
            // Sidebar without the "Settings" title
            List(selection: $selectedScreen) {
                ForEach(screenManager.screens) { screen in
                    ScreenRowView(screen: screen)
                        .contentShape(Rectangle())
                        .tag(screen)
                        .padding(.vertical, 4)
                }
            }
            .listStyle(SidebarListStyle())
        } detail: {
            if let screen = selectedScreen {
                ScreenDetailView(screen: screen)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "display")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a display to configure")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if let screen = selectedScreen {
                    Text(screen.name)
                        .font(.system(size: 18, weight: .medium))
                }
            }
            
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    withAnimation { screenManager.refreshScreens() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

struct ScreenRowView: View {
    @ObservedObject var screen: Screen
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(screen.name)
                    .font(.headline)
                    .lineLimit(1)
                
                Spacer()
                
                if screen.videoPlayer != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.medium)
                }
            }
            
            Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ScreenDetailView: View {
    @ObservedObject var screen: Screen
    @EnvironmentObject private var screenManager: ScreenManager
    @State private var playbackSpeed: Double = 1.0
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Main content
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    displayHeader
                    
                    // Video preview section
                    videoPreviewSection
                    
                    // Playback controls section
                    if screen.videoPlayer != nil {
                        playbackControlsSection
                    }
                    
                    Spacer()
                }
                .padding(24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var displayHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "display")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(screen.name)
                    .font(.system(size: 24, weight: .medium))
                Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.bottom, 8)
    }
    
    private var videoPreviewSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Video Preview", systemImage: "film")
                    .font(.headline)
                
                if let player = screen.previewPlayer {
                    VideoPlayer(player: player)
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                } else {
                    FileSelectView(action: showFilePicker)
                }
            }
            .padding(16)
        }
    }
    
    private var playbackControlsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Playback Controls", systemImage: "slider.horizontal.3")
                    .font(.headline)
                
                VStack(spacing: 20) {
                    // Control buttons
                    HStack(spacing: 16) {
                        Button(action: showFilePicker) {
                            Label("Change Video", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                        
                        Button(action: {
                            screen.videoPlayer?.togglePlayback()
                        }) {
                            Label(
                                screen.videoPlayer?.isPlaying == true ? "Pause" : "Play",
                                systemImage: screen.videoPlayer?.isPlaying == true ? "pause.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Divider()
                    
                    // Playback speed control
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Playback Speed: \(String(format: "%.1fx", playbackSpeed))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 12) {
                            Image(systemName: "tortoise")
                                .foregroundColor(.secondary)
                            
                            Slider(value: $playbackSpeed, in: 0.5...2.0, step: 0.1)
                                .onChange(of: playbackSpeed) { oldValue, newValue in
                                    screen.videoPlayer?.setPlaybackSpeed(newValue)
                                    screenManager.updatePlaybackSpeed(newValue, for: screen)
                                }
                            
                            Image(systemName: "hare")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
    
    private func showFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                handleSelectedFile(url: url)
            }
        }
    }
    
    private func handleSelectedFile(url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to access file at \(url)")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
        } catch {
            print("Error creating security-scoped bookmark: \(error)")
        }
    }
}

struct FileSelectView: View {
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
                
                Text("Select Video")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
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
