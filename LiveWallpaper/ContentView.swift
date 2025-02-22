import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var screenManager: ScreenManager
    @State private var selectedScreenIndex: Int?
    
    var body: some View {
        NavigationView {
            List(screenManager.screens) { screen in
                ScreenRowView(screen: screen)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showFilePicker(for: screen)
                    }
            }
            .navigationTitle("Live Wallpaper")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: screenManager.refreshScreens) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 300)
    }
    
    private func showFilePicker(for screen: Screen) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                handleSelectedFile(url: url, screen: screen)
            }
        }
    }
    
    private func handleSelectedFile(url: URL, screen: Screen) {
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
