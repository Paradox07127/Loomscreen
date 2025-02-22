import AppKit
import AVKit

class VideoContainerView: NSView {
    private var playerLayer: AVPlayerLayer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setPlayer(_ player: AVPlayer?) {
        // Remove existing player layer first
        playerLayer?.removeFromSuperlayer()
        
        if let player = player {
            let layer = AVPlayerLayer(player: player)
            layer.frame = bounds
            layer.videoGravity = .resizeAspectFill
            self.layer?.addSublayer(layer)
            self.playerLayer = layer
        }
    }
    
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }
    
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            playerLayer?.contentsScale = scale
        }
    }
}
