import AppKit
import AVKit
import LiveWallpaperCore

// MARK: - PlayerHostView

/// NSView whose backing layer is an AVPlayerLayer.
final class PlayerHostView: NSView {

    /// Last-applied user color-space preference. Kept so window movement /
    /// re-attach paths re-derive the right `CGColorSpace` without forcing
    /// callers to re-thread the preference each time.
    private var colorSpacePreference: VideoColorSpace = .auto

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
    func setExtendedDynamicRangeEnabled(_ enabled: Bool) {
        guard let playerLayer else { return }
        if #available(macOS 26, *) {
            playerLayer.preferredDynamicRange = enabled ? .high : .standard
        } else if playerLayer.responds(to: NSSelectorFromString("setWantsExtendedDynamicRangeContent:")) {
            playerLayer.setValue(enabled, forKey: "wantsExtendedDynamicRangeContent")
        }
    }

    /// Pin the underlying `AVPlayerLayer` to a specific `CGColorSpace`.
    /// `.auto` clears the override so AVFoundation's default colour path
    /// takes over; the other cases force a specific gamut so users can
    /// debug colour mismatches between displays or commit to wide-gamut
    /// output even on a content stream whose metadata says otherwise.
    ///
    /// `.rec2020HDR` also enables EDR output — HDR primaries without EDR
    /// would tone-map back to SDR for no benefit.
    func setColorSpacePreference(_ preference: VideoColorSpace) {
        colorSpacePreference = preference
        guard let playerLayer else { return }
        let space: CGColorSpace?
        switch preference {
        case .auto:        space = nil
        case .sRGB:        space = CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3:   space = CGColorSpace(name: CGColorSpace.displayP3)
        case .rec2020HDR:  space = CGColorSpace(name: CGColorSpace.itur_2020)
        // `.forceSDR` relies on the Rec.709 `AVVideoComposition` installed
        // by `WallpaperVideoPlayer` — the layer-level colorspace stays nil
        // so the composition's color attachments drive the output.
        case .forceSDR:    space = nil
        }
        // `CALayer.colorspace` is the right knob but the AVPlayerLayer Swift
        // surface doesn't expose it as a typed property — fall back to KVC.
        // `setValue(_:forKey:)` walks the same backing storage; AppKit / Core
        // Animation honour it identically.
        if let space {
            playerLayer.setValue(space, forKey: "colorspace")
        } else {
            playerLayer.setValue(nil, forKey: "colorspace")
        }
        // EDR coupling: HDR primaries are only meaningful with EDR output on.
        // For HDR primaries (`.rec2020HDR`) we force EDR on; for the explicit
        // SDR override (`.forceSDR`) we force EDR off so the layer doesn't
        // boost the tone-mapped Rec.709 frames back into HDR range.
        switch preference {
        case .rec2020HDR:
            setExtendedDynamicRangeEnabled(true)
        case .forceSDR:
            setExtendedDynamicRangeEnabled(false)
        case .auto, .sRGB, .displayP3:
            break
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

    func applyColorSpacePreference(_ preference: VideoColorSpace) {
        playerHostView.setColorSpacePreference(preference)
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
