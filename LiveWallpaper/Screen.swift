import AppKit
import SwiftUI
import AVKit

class Screen: Identifiable, Hashable, ObservableObject {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let nsScreen: NSScreen
    var videoPlayer: WallpaperVideoPlayer?
    @Published var previewPlayer: AVPlayer?
    
    init(nsScreen: NSScreen) {
        self.nsScreen = nsScreen
        self.id = nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        self.name = "Display \(id)"
        self.frame = nsScreen.frame
    }
    
    // Implement Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // Implement Equatable
    static func == (lhs: Screen, rhs: Screen) -> Bool {
        lhs.id == rhs.id
    }
}

struct ScreenRowView: View {
    @ObservedObject var screen: Screen
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(screen.name)
                    .font(.headline)
                Text("Resolution: \(Int(screen.frame.width))×\(Int(screen.frame.height))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if screen.videoPlayer != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 4)
    }
}
