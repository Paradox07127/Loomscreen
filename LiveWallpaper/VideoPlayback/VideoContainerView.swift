import AppKit
import AVKit

// MARK: - PlayerHostView

/// Layer-hosting NSView whose backing layer **is** an `AVPlayerLayer`.
///
/// This is the Apple-recommended way to embed an `AVPlayerLayer` into an NSView
/// hierarchy: by overriding `makeBackingLayer()` we make the player layer the
/// view's *own* layer instead of injecting it as a manual sublayer. The view
/// then participates correctly in `subviews` ordering, so sibling subviews
/// (e.g. the particle overlay) reliably render above the video without any
/// `zPosition` or `insertSublayer(at:)` tricks.
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

/// Hosts the video player **and** the particle overlay as a single unit so the
/// caller can never accidentally hand subview frames in the wrong coordinate
/// space (the previous bug — see `setParticleEffect`'s docstring).
///
/// Layout contract: both subviews are created with `origin: .zero` and the
/// container's local size, then sized via `autoresizingMask`. The video host
/// is the first subview and the particle overlay is the second, so NSView's
/// deterministic subview ordering renders particles above the video.
class VideoContainerView: NSView {

    // MARK: - Subviews

    private let playerHostView: PlayerHostView
    private let particleOverlayView: ParticleOverlayView
    private var currentPlayer: AVPlayer?

    var fitMode: VideoFitMode = .aspectFill {
        didSet {
            guard oldValue != fitMode else { return }
            playerHostView.setVideoGravity(fitMode.avLayerVideoGravity)
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        // Both subviews are created in the container's local coordinate space
        // (origin = .zero) — passing the container's frame directly would put
        // them at the parent's screen offset and clip them out of view on any
        // monitor with a non-zero origin. This was the long-standing
        // "particles never visible on the secondary monitor" bug.
        let localBounds = NSRect(origin: .zero, size: frameRect.size)
        playerHostView = PlayerHostView(frame: localBounds)
        playerHostView.autoresizingMask = [.width, .height]
        particleOverlayView = ParticleOverlayView(frame: localBounds)
        particleOverlayView.autoresizingMask = [.width, .height]

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

        // Order matters: playerHostView is the bottom subview (index 0),
        // particleOverlayView is the top subview (index 1). NSView subview
        // order determines composition order, so particles render above video.
        addSubview(playerHostView)
        addSubview(particleOverlayView)

        if let window = window {
            layer?.contentsScale = window.backingScaleFactor
        }
    }

    // MARK: - Public API — Video

    func setPlayer(_ player: AVPlayer?) {
        if player === currentPlayer { return }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.currentPlayer = player
            self.playerHostView.setVideoGravity(self.fitMode.avLayerVideoGravity)
            self.playerHostView.setPlayer(player)
        }
    }

    // MARK: - Public API — Particles

    /// Updates the active particle effect overlay. Density is a 0.05–3.0
    /// multiplier on the emitter's master birth rate. Pass `.none` to disable.
    func setParticleEffect(_ effect: ParticleEffect, density: Double) {
        particleOverlayView.setEffect(effect, density: CGFloat(density))
    }

    /// Adjusts particle density without rebuilding the emitter. Existing
    /// particles continue their lifecycle smoothly.
    func setParticleDensity(_ density: Double) {
        particleOverlayView.updateDensity(CGFloat(density))
    }

    // MARK: - Layout
    //
    // No manual frame propagation: both subviews use `autoresizingMask`, so
    // AppKit resizes them automatically. Manually setting frames from inside
    // `layout()` triggers a layout-recursion warning.

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
