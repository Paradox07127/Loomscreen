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
        
        // Change this line to hide all native controls
        playerView.controlsStyle = .none  // Hide all native controls
        
        // Apply video gravity based on fit mode
        playerView.videoGravity = fitMode.avLayerVideoGravity
        
        // Performance optimizations
        playerView.allowsPictureInPicturePlayback = false
        playerView.showsFullScreenToggleButton = false
        
        // Additional playback optimizations for the player itself
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        
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
}
