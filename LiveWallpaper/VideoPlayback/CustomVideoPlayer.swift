import SwiftUI
import AppKit
import AVKit

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

/// `intrinsicContentSize = .zero` lets the SwiftUI parent own all layout decisions.
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
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
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
