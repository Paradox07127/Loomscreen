import AppKit
import AVKit

class VideoContainerView: NSView {
    private var playerLayer: AVPlayerLayer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        
        // Performance optimizations
        layer?.drawsAsynchronously = true
        layer?.shouldRasterize = true
        layer?.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2.0
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setPlayer(_ player: AVPlayer?) {
        DispatchQueue.main.async { [weak self] in
            self?.playerLayer?.removeFromSuperlayer()
            
            if let player = player {
                let layer = AVPlayerLayer(player: player)
                layer.frame = self?.bounds ?? .zero
                layer.videoGravity = .resizeAspectFill
                layer.drawsAsynchronously = true
                self?.layer?.addSublayer(layer)
                self?.playerLayer = layer
                self?.updatePlayerLayerScale()
            }
        }
    }
    
    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }
    
    private func updatePlayerLayerScale() {
        guard let scale = window?.backingScaleFactor else { return }
        playerLayer?.contentsScale = scale
    }
    
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePlayerLayerScale()
    }
}
