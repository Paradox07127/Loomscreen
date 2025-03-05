import SwiftUI
import AVKit

// A custom NSViewRepresentable wrapper for AVPlayerView to ensure compatibility
// and avoid SwiftUI's VideoPlayer implementation that might cause crashes
struct CustomVideoPlayer: NSViewRepresentable {
    var player: AVPlayer
    var fitMode: VideoFitMode = .aspectFill
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none
        
        // Apply video gravity based on fit mode
        playerView.videoGravity = fitMode.avLayerVideoGravity
        
        // Configure for better performance
        playerView.allowsPictureInPicturePlayback = false
        
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Update player if it has changed
        if nsView.player !== player {
            nsView.player = player
        }
        
        // Update video gravity if fit mode has changed
        nsView.videoGravity = fitMode.avLayerVideoGravity
    }
    
    // Implement Coordinator for handling player notifications if needed
    class Coordinator: NSObject {
        var parent: CustomVideoPlayer
        
        init(_ parent: CustomVideoPlayer) {
            self.parent = parent
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}

// Optional extension for additional configuration
extension CustomVideoPlayer {
    // Sets the video fit mode
    func videoFitMode(_ mode: VideoFitMode) -> CustomVideoPlayer {
        var view = self
        view.fitMode = mode
        return view
    }
}
