import AppKit
import AVKit

// MARK: - PlayerHostView

/// NSView whose backing layer is an AVPlayerLayer.
final class PlayerHostView: NSView {

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    func setPlayer(_ player: AVPlayer?) {
        playerLayer?.player = player
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        playerLayer?.contentsScale = scale
        playerLayer?.drawsAsynchronously = true
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        playerLayer?.videoGravity = gravity
    }

    /// Forwards an HDR / EDR preference to the underlying `AVPlayerLayer`.
    /// Uses `preferredDynamicRange` on macOS 26+, falls back to the older
    /// `wantsExtendedDynamicRangeContent` selector on macOS 14-25, and is a
    /// no-op below 14 so HDR videos still render (just tone-mapped to SDR).
    func setExtendedDynamicRangeEnabled(_ enabled: Bool) {
        guard let playerLayer else { return }
        if #available(macOS 26, *) {
            playerLayer.preferredDynamicRange = enabled ? .high : .standard
        } else if playerLayer.responds(to: NSSelectorFromString("setWantsExtendedDynamicRangeContent:")) {
            playerLayer.setValue(enabled, forKey: "wantsExtendedDynamicRangeContent")
        }
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            playerLayer?.contentsScale = scale
        }
    }
}

// MARK: - VideoContainerView

/// Keeps the video layer and particle overlay in one local coordinate space.
class VideoContainerView: NSView {

    // MARK: - Subviews

    private let playerHostView: PlayerHostView
    private let particleOverlayView: ParticleOverlayView
    private var currentPlayer: AVPlayer?
    private var spanRenderConfiguration: VideoSpanRenderConfiguration?

    var fitMode: VideoFitMode = .aspectFill {
        didSet {
            guard oldValue != fitMode else { return }
            playerHostView.setVideoGravity(fitMode.avLayerVideoGravity)
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        let localBounds = NSRect(origin: .zero, size: frameRect.size)
        playerHostView = PlayerHostView(frame: localBounds)
        playerHostView.autoresizingMask = []
        particleOverlayView = ParticleOverlayView(frame: localBounds)
        particleOverlayView.autoresizingMask = []

        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = .clear
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.drawsAsynchronously = true
        layer?.masksToBounds = true

        // Subview order keeps particles above the video.
        addSubview(playerHostView)
        addSubview(particleOverlayView)

        if let window = window {
            layer?.contentsScale = window.backingScaleFactor
        }
    }

    // MARK: - Public API — Video

    func setPlayer(_ player: AVPlayer?) {
        if player === currentPlayer { return }

        currentPlayer = player
        playerHostView.setVideoGravity(fitMode.avLayerVideoGravity)
        playerHostView.setPlayer(player)
    }

    func applyHDRPreference(_ enabled: Bool) {
        playerHostView.setExtendedDynamicRangeEnabled(enabled)
    }

    func setSpanRenderConfiguration(_ configuration: VideoSpanRenderConfiguration?) {
        guard spanRenderConfiguration != configuration else { return }
        spanRenderConfiguration = configuration
        needsLayout = true
    }

    // MARK: - Public API — Particles

    func setParticleEffect(_ effect: ParticleEffect, density: Double) {
        particleOverlayView.setEffect(effect, density: CGFloat(density))
    }

    func setParticleDensity(_ density: Double) {
        particleOverlayView.updateDensity(CGFloat(density))
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        if let spanRenderConfiguration {
            playerHostView.frame = spanRenderConfiguration.canvasFrameInScreenCoordinates
        } else {
            playerHostView.frame = bounds
        }
        particleOverlayView.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
    }

    // MARK: - Memory Management

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            playerHostView.setPlayer(nil)
            particleOverlayView.setEffect(.none, density: 0)
            currentPlayer = nil
        }
    }
}
