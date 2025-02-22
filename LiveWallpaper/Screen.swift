import AppKit
import SwiftUI

struct Screen: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let nsScreen: NSScreen
    var videoPlayer: WallpaperVideoPlayer?
    
    init(nsScreen: NSScreen) {
        self.nsScreen = nsScreen
        self.id = nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        self.name = "Display \(id)"
        self.frame = nsScreen.frame
    }
}

struct ScreenRowView: View {
    let screen: Screen
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(screen.name)
                .font(.headline)
            Text("Resolution: \(Int(screen.frame.width))×\(Int(screen.frame.height))")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
