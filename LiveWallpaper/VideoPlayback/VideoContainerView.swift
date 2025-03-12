import AppKit
import AVKit
import Combine

// Container view for video playback that handles the AVPlayerLayer
class VideoContainerView: NSView {
    // MARK: - Properties
    private var playerLayer: AVPlayerLayer?
    private var cleanupTasks: Set<AnyCancellable> = []
    private var currentPlayer: AVPlayer?
    
    var fitMode: VideoFitMode = .aspectFill {
        didSet {
            if oldValue != fitMode {
                playerLayer?.videoGravity = fitMode.avLayerVideoGravity
            }
        }
    }
    
    // MARK: - Initialization
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        
        setupView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupView() {
        // Ensure proper layer initialization
        wantsLayer = true
        layer?.backgroundColor = .clear
        
        // Configure view for optimal video rendering
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        
        // Add these lines for better performance
        layer?.drawsAsynchronously = true
        layer?.masksToBounds = true  // Prevent drawing outside bounds
        
        // Adjust for high-DPI displays
        if let window = window {
            layer?.contentsScale = window.backingScaleFactor
        }
    }
    
    // MARK: - Player Configuration
    // Set the player for this view
    func setPlayer(_ player: AVPlayer?) {
        // Skip update if it's the same player
        if player === currentPlayer { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Remove existing player layer
            self.cleanupPlayerLayer()
            self.currentPlayer = player
            
            guard let player = player else {
                self.playerLayer = nil
                return
            }
            
            // Create and configure new player layer
            let newLayer = AVPlayerLayer(player: player)
            newLayer.frame = self.bounds
            newLayer.videoGravity = self.fitMode.avLayerVideoGravity

            // Apply performance optimizations
            newLayer.drawsAsynchronously = true
            newLayer.shouldRasterize = false  // Don't rasterize video content
            newLayer.allowsEdgeAntialiasing = true  // Smoother edges

            // Set proper scale factor for Retina displays
            let scale = self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            newLayer.contentsScale = scale
            
            // Add layer and store reference
            self.layer?.addSublayer(newLayer)
            self.playerLayer = newLayer
            
            // Ensure proper initial frame
            self.updatePlayerLayerFrame()
        }
    }
    
    private func cleanupPlayerLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        
        CATransaction.commit()
    }
    
    // MARK: - Layout & Scaling
    private func updatePlayerLayerFrame() {
        guard !bounds.isEmpty else { return }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // Ensure player layer covers the full bounds
        playerLayer?.frame = bounds
        
        // Log frame updates for debugging
        Logger.debug("Updated player layer frame to \(bounds)", category: .videoPlayer)
        
        CATransaction.commit()
    }
    
    override func layout() {
        super.layout()
        updatePlayerLayerFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePlayerLayerFrame()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        
        if let scale = window?.backingScaleFactor {
            playerLayer?.contentsScale = scale
        }
    }
    
    // MARK: - Memory Management
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        
        if newWindow == nil {
            // View is being removed from window, clean up resources
            cleanupPlayerLayer()
            currentPlayer = nil
        }
    }
    
    deinit {
        cleanupTasks.removeAll()
        cleanupPlayerLayer()
    }
}
