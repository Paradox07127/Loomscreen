import SwiftUI
import UniformTypeIdentifiers
import AVKit

struct ContentView: View {
    @EnvironmentObject private var screenManager: ScreenManager
    @State private var selectedScreen: Screen?
    
    var body: some View {
        NavigationSplitView {
            // Left sidebar with screens list
            List(screenManager.screens, selection: $selectedScreen) { screen in
                ScreenRowView(screen: screen)
                    .contentShape(Rectangle())
                    .tag(screen)
            }
            .navigationTitle("Displays")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: screenManager.refreshScreens) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        } detail: {
            // Right content area
            if let screen = selectedScreen {
                ScreenDetailView(screen: screen)
            } else {
                Text("Select a display to configure")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

struct ScreenDetailView: View {
    @ObservedObject var screen: Screen
    @EnvironmentObject private var screenManager: ScreenManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Video Preview and Controls
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        if let player = screen.previewPlayer {
                            VideoPlayer(player: player)
                                .frame(width: nil, height: 250)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Button(action: { showFilePicker() }) {
                                VStack {
                                    Image(systemName: "plus.circle")
                                        .font(.largeTitle)
                                    Text("Select Video")
                                }
                            }
                            .frame(width: nil, height: 250)
                            .background(Color.gray.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        
                        if screen.videoPlayer != nil {
                            HStack {
                                Button(action: { showFilePicker() }) {
                                    Text("Change Video")
                                }
                                
                                Spacer()
                                
                                Button(action: {
                                    screen.videoPlayer?.togglePlayback()
                                }) {
                                    Text(screen.videoPlayer?.isPlaying == true ? "Pause" : "Play")
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .padding()
        }
        .navigationTitle(screen.name)
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
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            screenManager.setVideo(
                url: url,
                bookmarkData: bookmarkData,
                for: screen
            )
        } catch {
            print("Error creating security-scoped bookmark: \(error)")
        }
    }
}
