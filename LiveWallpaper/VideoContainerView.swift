import AppKit
import AVKit

class VideoContainerView: NSView {
    private var playerLayer: AVPlayerLayer?
    private var frameObserver: Any?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = .clear
        
        // Observe frame changes
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.updatePlayerLayerFrame()
        }
    }
    
    func setPlayer(_ player: AVPlayer?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Remove existing player layer first
            self.playerLayer?.removeFromSuperlayer()
            
            if let player = player {
                let layer = AVPlayerLayer(player: player)
                layer.frame = self.bounds
                layer.videoGravity = .resizeAspectFill
                layer.contentsScale = self.window?.backingScaleFactor ?? 2.0
                
                // Add layer and store reference
                self.layer?.addSublayer(layer)
                self.playerLayer = layer
                
                // Initial frame update
                self.updatePlayerLayerFrame()
            }
        }
    }
    
    private func updatePlayerLayerFrame() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.playerLayer?.frame = self.bounds
            CATransaction.commit()
        }
    }
    
    override func layout() {
        super.layout()
        updatePlayerLayerFrame()
    }
    
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        DispatchQueue.main.async { [weak self] in
            if let scale = self?.window?.backingScaleFactor {
                self?.playerLayer?.contentsScale = scale
            }
        }
    }
    
    deinit {
        if let observer = frameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
