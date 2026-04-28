import SwiftUI
import AppKit
import AVKit

/// SwiftUI wrapper around an `AVPlayerLayer` with stable sizing and clear chrome.
struct CustomVideoPlayer: NSViewRepresentable {
    var player: AVPlayer
    var fitMode: VideoFitMode = .aspectFill

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let host = PlayerLayerHostView()
        host.attach(player: player, gravity: fitMode.avLayerVideoGravity)
        return host
    }

    func updateNSView(_ host: PlayerLayerHostView, context: Context) {
        if host.player !== player {
            host.attach(player: player, gravity: fitMode.avLayerVideoGravity)
        } else {
            host.gravity = fitMode.avLayerVideoGravity
        }

        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
    }
}

/// NSView hosting an `AVPlayerLayer`. The layer tracks the view's bounds with
/// a transparent background; `intrinsicContentSize = .zero` lets the SwiftUI
/// parent own all layout decisions.
final class PlayerLayerHostView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? { playerLayer.player }

    var gravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        // Host view: transparent.
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        // Player layer: transparent too, so letterbox areas don't show black.
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    /// Refuse to expose the video's native resolution as intrinsic size — SwiftUI owns layout.
    override var intrinsicContentSize: NSSize { .zero }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func attach(player: AVPlayer, gravity: AVLayerVideoGravity) {
        playerLayer.player = player
        playerLayer.videoGravity = gravity
    }
}
