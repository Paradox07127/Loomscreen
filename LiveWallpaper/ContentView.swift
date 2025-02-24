import SwiftUI
import AppKit
import AVKit

struct ContentView: View {
    @EnvironmentObject private var screenManager: ScreenManager
    @State private var selectedNavigation: Navigation?
    
    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selectedNavigation)
        } detail: {
            DetailContent(selection: selectedNavigation)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Navigation Enum
enum Navigation: Hashable {
    case general
    case screen(CGDirectDisplayID)
    
    var title: String {
        switch self {
        case .general: return "General"
        case .screen: return "Screen"
        }
    }
    
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .screen: return "display"
        }
    }
}

// MARK: - Sidebar View
private struct Sidebar: View {
    @Binding var selection: Navigation?
    @EnvironmentObject private var screenManager: ScreenManager
    
    var body: some View {
        List(selection: $selection) {
            NavigationLink(value: Navigation.general) {
                Label("General", systemImage: "gearshape")
            }
            
            Section("Displays") {
                ForEach(screenManager.screens, id: \.id) { screen in
                    NavigationLink(value: Navigation.screen(screen.id)) {
                        ScreenRow(screen: screen)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }
}

// MARK: - Screen Row
private struct ScreenRow: View {
    @ObservedObject var screen: Screen
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(screen.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                Spacer()
                
                if screen.videoPlayer != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)
                }
            }
            
            Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail Content
private struct DetailContent: View {
    let selection: Navigation?
    @EnvironmentObject private var screenManager: ScreenManager
    
    var body: some View {
        Group {
            switch selection {
            case .general:
                GeneralSettingsView()
            case .screen(let screenId):
                if let screen = screenManager.screens.first(where: { $0.id == screenId }) {
                    ScreenDetailView(screen: screen)
                } else {
                    EmptyStateView(message: "Screen not found")
                }
            case .none:
                EmptyStateView(message: "Select a display to configure")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
}

// MARK: - Empty State View
private struct EmptyStateView: View {
    let message: String
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "display")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text(message)
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScreenDetailView: View {
    @ObservedObject var screen: Screen
    @EnvironmentObject private var screenManager: ScreenManager
    @State private var playbackSpeed: Double = 1.0
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                displayHeader
                videoPreviewSection
                if screen.videoPlayer != nil {
                    playbackControlsSection
                }
                Spacer()
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
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
                        .font(.system(size: 24, weight: .medium))
                    Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button(action: {
                screenManager.reloadVideoForScreen(screen)
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .help("Reload Video")
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
                    HStack(spacing: 16) {
                        Button(action: showFilePicker) {
                            Label("Change Video", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                        
                        // Updated playback toggle
                        Button(action: {
                            if screen.videoPlayer?.isPlaying ?? false {
                                screen.videoPlayer?.pause()
                            } else {
                                screen.videoPlayer?.play()
                            }
                            screen.objectWillChange.send()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: screen.videoPlayer?.isPlaying ?? false ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 20))
                                Text(screen.videoPlayer?.isPlaying ?? false ? "Pause" : "Play")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Divider()
                    
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
        // First, check if we can access the file
        let canAccess = url.startAccessingSecurityScopedResource()
        
        guard canAccess else {
            print("Failed to access file at \(url)")
            // You might want to show an alert to the user here
            return
        }
        
        do {
            // Create security-scoped bookmark
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: [
                    .isReadableKey,
                    .fileSizeKey,
                    .contentTypeKey
                ],
                relativeTo: nil
            )
            
            // Verify we can resolve the bookmark
            var isStale = false
            let _ = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                print("Warning: Bookmark is stale, but resolved successfully")
            }
            
            // If everything is okay, set the video
            screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
            
        } catch {
            print("Error creating security-scoped bookmark: \(error)")
            // You might want to show an alert to the user here
        }
        
        url.stopAccessingSecurityScopedResource()
    }
}

private struct FileSelectView: View {
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


// MARK: - Preview Provider
#Preview {
    ContentView()
        .environmentObject(ScreenManager())
}

